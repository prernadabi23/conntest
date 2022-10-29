open Lwt.Infix
open Lwt_result.Syntax

module Output = Output

let (let*) = Result.bind 
let (let+) x f = Result.map f x 

module type Protocol_S = sig 

  module Listen : sig 
    val start : name:string -> port:int -> timeout:int -> unit
  end

  module Connect : sig
    val start :
      name:string ->
      port:int ->
      ip:Ipaddr.t ->
      monitor_bandwidth:< enabled : bool; packet_size : int; .. > ->
      timeout:int ->
      'a Lwt.t
  end

end


module type S = sig

  module Tcp : Protocol_S
  module Udp : Protocol_S

end

module type STACK_V = sig
  type t 
  val stack : t
end

module Make
    (Time : Mirage_time.S)
    (S : Tcpip.Stack.V4V6)
    (Sv : STACK_V with type t = S.t)
    (O : Output.S)
= struct

  let error_to_msg pp v =
    v >>= function
    | Ok v -> Lwt_result.return v
    | Error err ->
      let msg = Fmt.str "%a" pp err in
      Lwt_result.fail @@ `Msg msg

  module Tcp_flow = struct
    include S.TCP

    type t = S.TCP.flow

    let tcp_stack = S.tcp Sv.stack

    let listen ~port callback =
      S.TCP.listen tcp_stack ~port callback

    let unlisten ~port =
      S.TCP.unlisten tcp_stack ~port 

    let create_connection ~id:_ dst =
      S.TCP.create_connection tcp_stack dst
      |> error_to_msg S.TCP.pp_error

    let read flow = S.TCP.read flow |> error_to_msg S.TCP.pp_error

    let writev flow data =
      S.TCP.writev flow data |> error_to_msg S.TCP.pp_write_error

  end
  
  module Tcp = Protocol.Make(Time)(Tcp_flow)(O)(struct
    let subproto = `Tcp
  end)

  module Ring = struct

    type 'a t = {
      ring : 'a option array;
      index : int;
    }

    let make n : 'a t =
      let ring = Array.make n None in
      let index = 0 in
      { ring; index }

    let insert field r =
      let index = succ r.index mod Array.length r.ring in
      r.ring.(index) <- Some field;
      { r with index }

    let get_previous r i =
      let len = Array.length r.ring in
      if i >= len then None else
        let ci = r.index in
        let i_wrapped =
          if i <= ci then ci - i else len + (ci - i)
        in
        r.ring.(i_wrapped)
    
    let get_latest r = get_previous r 0

  end

  module Udp_flow = struct
    (* include S.UDP *)

    let ring_size = 5

    type ring_field = {
      data : Cstruct.t option; (*None => packet is late*)
      packet_index : int;
      (*< goto this field could be avoided, as packet bears this info,
        .. and it's calculated from prev packet otherwise*)
    }
    
    type t = {
      source : Cstruct.t Mirage_flow.or_eof Lwt_mvar.t;
      port : int;
      pier : Ipaddr.t;
      pier_port : int;
      conn_id : string;
      ringbuffer : ring_field Ring.t;
      feeder : unit Lwt.t;
    }

    let udp_stack = S.udp Sv.stack

    module Conn_map = Map.Make(String)

    (*> Warning: but don't know why you would run two instances of protocol*)
    let conn_map = ref (Conn_map.empty)

    (*goto insert latest available ringbuffer packet in source-mvar
     * @problem; if user_callback doesn't loop quickly enough over
      source-mvar, then packets will get lost
       * @solution; make source-mvar into source-stream (infinite)
        * this way:
          * ringbuffer is only about receiving
          * source-stream is only about buffering for user_callback
            * @problem; can lead to memory-leak if user_callback is
              generally too slow
              * @solution; just use mvar - client shall be faster than
                data comes in
    *)
    let feed_source ~source ~ringbuffer =
      failwith "todo"
    
    let listen ~port user_callback =
      let callback ~src ~dst ~src_port data =
        match Packet.Tcp.init ~ignore_data:true data with
        | Ok (`Done (packet, _rest)) ->
          let conn_id = packet.Packet.T.header.connection_id in
          begin match Conn_map.find_opt conn_id !conn_map with
          | None -> 
            let source = Lwt_mvar.create_empty () in  (* @@ `Data data *)
            let ringbuffer =
              let data = Some data in
              let packet_index = packet.Packet.T.header.index in
              Ring.make ring_size
              |> Ring.insert { data; packet_index }
            in
            let feeder = feed_source ~source ~ringbuffer in
            let flow = {
              source;
              port;
              pier = src;
              pier_port = src_port;
              conn_id;
              ringbuffer;
              feeder;
            } in
            let conn_map' = Conn_map.add conn_id flow !conn_map in
            conn_map := conn_map';
            (*> goto: this blocks, as the lifetime of this callback is longer
              * .. this depends on semantics of S.UDP.listen -
                * does it spin up all possible callbacks when recvd packet?
                  * or does it block recv nxt pkt on blocking callback?
              * @solution;
                * alternative is just to run this async
            *)
            user_callback flow
          | Some flow ->
            (*> goto do this in async ringbuffer loop instead*)
            (* Lwt_mvar.put flow.source @@ `Data data
            *)
            (*> goto insert packet in ringbuffer (a mutation)*)
            (*> goto problem; flow is kept for a long time by user code
              * .. so it needs to be mutated instead of Conn_map begin updated!
            *)
            Lwt.return_unit
          end
        (*> goto change interface of 'listen' to return Result.t instead*)
        | Ok (`Unfinished _) ->
          failwith "Udp_flow: `Unfinished is unsupported for UDP"
        | Error (`Msg err) ->
          failwith ("Udp_flow: Error: "^err) 
      in
      S.UDP.listen udp_stack ~port callback

    let unlisten ~port =
      S.UDP.unlisten udp_stack ~port 

    module Udp_port = struct 
    
      module PSet = Set.Make(Int)

      let used_ports = ref PSet.empty

      (*goto depends on Random.init done somewhere*)
      let rec allocate () =
        let port = 10_000 + Random.int 50_000 in
        if PSet.mem port !used_ports then
          allocate ()
        else
          let used_ports' = PSet.add port !used_ports in
          used_ports := used_ports';
          port

      let free port =
        let used_ports' = PSet.remove port !used_ports in
        used_ports := used_ports'
      
    end

    (*goto problem; how to setup a two-way connection here?
      * notes;
        * it's easy to get src and src_port when receiving packet
          * (but don't know if it works to send back to this)
      * @solution
        * try using a specific sending port when sending first packet
          * < keep track of these used ports 
          * register this port in flow too
            * which shall be used
              * when 'write'
              * to setup a listener here on 'create_connection'
                * and ringbuffer should be created by 'listen' instead then
                * @problem; how to reuse the flow between listen and create_connection?
    *)
    (*> goto this also need to startup async ringbuffer/source handler
      .. maybe reuse code with 'listen'?
        * @brian; can this just call 'listen' instead of creating own flow?
          * no; callback is run when first packet is received
            * and this is too late to receive 'flow'
              * here it need be returned right away 
    *)
    let create_connection ~id (pier, pier_port) =
      let source = Lwt_mvar.create_empty () in
      let port = Udp_port.allocate () in
      let ringbuffer = Ring.make ring_size in
      let feeder = feed_source ~source ~ringbuffer in
      let flow = {
        source;
        port;
        pier;
        pier_port;
        conn_id = id;
        ringbuffer;
        feeder;
      } in
      let conn_map' = Conn_map.add id flow !conn_map in
      conn_map := conn_map';
      Lwt_result.return flow

    let read flow =
      Lwt_mvar.take flow.source >|= fun res ->
      Ok res

    (*> Note: it's important that all cstructs are written at once for ordering*)
    let writev flow datas =
      let data = Cstruct.concat datas in
      let src_port = flow.port in
      let dst, dst_port = flow.pier, flow.pier_port in
      (*< spec:
        * listen-case: flow is only given to callback on recv first packet
        * connect-case: flow already has dst + dst_port
      *)
      S.UDP.write ~src_port ~dst ~dst_port udp_stack data
      |> error_to_msg S.UDP.pp_error

    let dst flow = flow.pier, flow.pier_port

    (*goto cancel async thread that feeds data from ringbuffer to source*)
    let close flow =
      Lwt.cancel flow.feeder;
      let conn_map' = Conn_map.remove flow.conn_id !conn_map in
      conn_map := conn_map';
      Udp_port.free flow.port;
      Lwt.return_unit
    
  end
  
  module Udp = Protocol.Make(Time)(Udp_flow)(O)(struct
    let subproto = `Udp
  end)

end
