
open Solver_types

(* TODO: normalization of {!term_cell} for use in signatures? *)

type 'a view = 'a Solver_types.term_view =
  | Bool of bool
  | App_cst of cst * 'a IArray.t
  | If of 'a * 'a * 'a

type t = term view

module type ARG = sig
  type t
  val hash : t -> int
  val equal : t -> t -> bool
  val pp : t Fmt.printer
end

module Make_eq(A : ARG) = struct
  let sub_hash = A.hash
  let sub_eq = A.equal

  let hash (t:A.t view) : int = match t with
    | Bool b -> Hash.bool b
    | App_cst (f,l) ->
      Hash.combine3 4 (Cst.hash f) (Hash.iarray sub_hash l)
    | If (a,b,c) -> Hash.combine4 7 (sub_hash a) (sub_hash b) (sub_hash c)

  (* equality that relies on physical equality of subterms *)
  let equal (a:A.t view) b : bool = match a, b with
    | Bool b1, Bool b2 -> CCBool.equal b1 b2
    | App_cst (f1, a1), App_cst (f2, a2) ->
      Cst.equal f1 f2 && IArray.equal sub_eq a1 a2
    | If (a1,b1,c1), If (a2,b2,c2) ->
      sub_eq a1 a2 && sub_eq b1 b2 && sub_eq c1 c2
    | Bool _, _ | App_cst _, _ | If _, _
      -> false

  let pp = Solver_types.pp_term_view_gen ~pp_id:ID.pp_name ~pp_t:A.pp
end[@@inline]

include Make_eq(struct
    type t = term
    let equal (t1:t) t2 = t1==t2
    let hash (t:term): int = t.term_id
    let pp = pp_term
  end)

let true_ = Bool true
let false_ = Bool false

let app_cst f a = App_cst (f, a)
let const c = App_cst (c, IArray.empty)

let if_ a b c =
  assert (Ty.equal b.term_ty c.term_ty);
  If (a,b,c)

let ty (t:t): Ty.t = match t with
  | Bool _ -> Ty.prop
  | App_cst (f, args) ->
    begin match Cst.view f with
      | Cst_undef fty -> 
        let ty_args, ty_ret = Ty.Fun.unfold fty in
        (* check arity *)
        if List.length ty_args <> IArray.length args then (
          Error.errorf "Term_cell.apply: expected %d args, got %d@ in %a"
            (List.length ty_args) (IArray.length args) pp t

        );
        (* check types *)
        List.iteri
          (fun i ty_a ->
             let a = IArray.get args i in
             if not @@ Ty.equal a.term_ty ty_a then (
               Error.errorf "Term_cell.apply: %d-th argument mismatch:@ \
                             %a does not have type %a@ in %a"
                 i pp_term a Ty.pp ty_a pp t
             ))
          ty_args;
        ty_ret
      | Cst_def def -> def.ty f.cst_id args
    end
  | If (_,b,_) -> b.term_ty

module Tbl = CCHashtbl.Make(struct
    type t = term view
    let equal = equal
    let hash = hash
  end)

