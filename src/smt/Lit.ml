
open Solver_types

type t = lit

let neg l = {l with lit_sign=not l.lit_sign}

let sign t = t.lit_sign
let view (t:t): lit_view = t.lit_view

let abs t: t = {t with lit_sign=true}

let make ~sign v = {lit_sign=sign; lit_view=v}

(* assume the ID is fresh *)
let fresh_with id = make ~sign:true (Lit_fresh id)

(* fresh boolean literal *)
let fresh: unit -> t =
  let n = ref 0 in
  fun () ->
    let id = ID.makef "#fresh_%d" !n in
    incr n;
    make ~sign:true (Lit_fresh id)

let dummy = fresh()

let atom ?(sign=true) (t:term) : t =
  let t, sign' = Term.abs t in
  let sign = if not sign' then not sign else sign in
  make ~sign (Lit_atom t)

let eq tst a b = atom ~sign:true (Term.eq tst a b)
let neq tst a b = atom ~sign:false (Term.eq tst a b)
let expanded t = make ~sign:true (Lit_expanded t)

let cstor_test tst cstor t = atom ~sign:true (Term.cstor_test tst cstor t)

let as_atom (lit:t) : (term * bool) option = match lit.lit_view with
  | Lit_atom t -> Some (t, lit.lit_sign)
  | _ -> None

let hash = hash_lit
let compare = cmp_lit
let equal a b = compare a b = 0
let pp = pp_lit
let print = pp

let norm l =
  if l.lit_sign then l, Dagon_sat.Same_sign else neg l, Dagon_sat.Negated

module Set = CCSet.Make(struct type t = lit let compare=compare end)
module Tbl = CCHashtbl.Make(struct type t = lit let equal=equal let hash=hash end)
