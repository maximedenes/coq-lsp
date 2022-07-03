module CS = Stats

module InterpInfo = struct

  type t =
    { st : Vernacstate.t
    ; warnings : unit
    }

end

type interp_result = (InterpInfo.t, Loc.t option * Pp.t) result

let coq_interp ~st cmd =
  let st = Vernacinterp.interp ~st cmd in
  { InterpInfo.st; warnings = () }

module Stats = struct

  type 'a t = { res : 'a; cache_hit : bool; memory : int; time: float }

  let make ?(cache_hit=false) res = { res; cache_hit; memory = 0; time = 0.0 }

end

(* This requires a ppx likely as to ignore the CAst location *)
module VernacInput = struct

  type t = Vernacexpr.vernac_control * Vernacstate.t

  let equal (v1, st1) (v2, st2) =
    if compare v1.CAst.v v2.CAst.v = 0
    then
      if compare st1 st2 = 0
      then true
      else false
    else false

  let hash (v, st) = Hashtbl.hash (v.CAst.v, st)

end

let input_info (v,st) =
  Format.asprintf "stm: %d | st %d" (Hashtbl.hash v.CAst.v) (Hashtbl.hash st)

module HC = Hashtbl.Make(VernacInput)

type cache = interp_result HC.t
let cache : cache ref = ref (HC.create 1000)

let in_cache st stm =
  let kind = CS.Kind.Hashing in
  CS.record ~kind ~f:(HC.find_opt) !cache (stm, st)

let interp_command ~st stm : _ result Stats.t =
  match in_cache st stm with
  | Some st ->
    Lsp.Io.log_error "coq" "cache hit";
    Stats.make ~cache_hit:true st
  | None ->
    Lsp.Io.log_error "coq" "cache miss";
    let kind = CS.Kind.Exec in
    let res =
      CS.record ~kind
        ~f:(Coq_util.coq_protect (coq_interp ~st)) stm
    in
    let () = HC.add !cache (stm,st) res in
    Stats.make res

let mem_stats () = Obj.reachable_words (Obj.magic cache)

let load_from_disk ~file =
  let in_c = open_in_bin file in
  let in_cache : cache = Marshal.from_channel in_c in
  cache := in_cache;
  close_in in_c

let save_to_disk ~file =
  let out_c = open_out_bin file in
  let out_cache : cache = !cache in
  Marshal.to_channel out_c out_cache [Marshal.Closures];
  close_out out_c