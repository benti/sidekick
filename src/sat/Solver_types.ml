module type S = Solver_types_intf.S

module Var_fields = Solver_types_intf.Var_fields

let v_field_seen_neg = Var_fields.mk_field()
let v_field_seen_pos = Var_fields.mk_field()
let () = Var_fields.freeze()

module C_fields = Solver_types_intf.C_fields

let c_field_attached = C_fields.mk_field () (* watching literals? *)
let c_field_visited = C_fields.mk_field () (* used during propagation and proof generation. *)

(* Solver types for McSat Solving *)
(* ************************************************************************ *)

module Make (E : Theory_intf.S) = struct

  type formula = E.Form.t
  type proof = E.proof

  type var = {
    vid : int;
    pa : atom;
    na : atom;
    mutable v_fields : Var_fields.t;
    mutable v_level : int;
    mutable v_idx: int; (** position in heap *)
    mutable v_weight : float; (** Weight (for the heap), tracking activity *)
    mutable reason : reason option;
  }

  and atom = {
    aid : int;
    var : var;
    neg : atom;
    lit : formula;
    mutable is_true : bool;
    mutable watched : clause Vec.t;
  }

  and clause = {
    name : int;
    tag : int option;
    atoms : atom array;
    mutable cpremise : premise;
    mutable activity : float;
    mutable c_flags : C_fields.t
  }

  and reason =
    | Decision
    | Bcp of clause
    | Semantic

  and premise =
    | Hyp
    | Local
    | Lemma of proof
    | History of clause list

  let rec dummy_var =
    { vid = -101;
      pa = dummy_atom;
      na = dummy_atom;
      v_fields = Var_fields.empty;
      v_level = -1;
      v_weight = -1.;
      v_idx= -1;
      reason = None;
    }
  and dummy_atom =
    { var = dummy_var;
      lit = E.Form.dummy;
      watched = Obj.magic 0;
      (* should be [Vec.make_empty dummy_clause]
         but we have to break the cycle *)
      neg = dummy_atom;
      is_true = false;
      aid = -102;
    }
  let dummy_clause =
    { name = -1;
      tag = None;
      atoms = [| |];
      activity = -1.;
      c_flags = C_fields.empty;
      cpremise = History [];
    }

  let () = dummy_atom.watched <- Vec.make_empty dummy_clause

  (* Constructors *)
  module MF = Hashtbl.Make(E.Form)

  type t = {
    f_map: var MF.t;
    vars: var Vec.t;
    mutable cpt_mk_var: int;
    mutable cpt_mk_clause: int;
  }

  type state = t

  let create_ size_map size_vars () : t = {
    f_map = MF.create size_map;
    vars = Vec.make size_vars dummy_var;
    cpt_mk_var = 0;
    cpt_mk_clause = 0;
  }

  let create ?(size=`Big) () : t =
    let size_map, size_vars = match size with
      | `Tiny -> 8, 0
      | `Small -> 16, 10
      | `Big -> 4096, 128
    in
    create_ size_map size_vars ()

  let nb_elt st = Vec.size st.vars
  let get_elt st i = Vec.get st.vars i
  let iter_elt st f = Vec.iter f st.vars

  let name_of_clause c = match c.cpremise with
    | Hyp -> "H" ^ string_of_int c.name
    | Local -> "L" ^ string_of_int c.name
    | Lemma _ -> "T" ^ string_of_int c.name
    | History _ -> "C" ^ string_of_int c.name

  module Var = struct
    type t = var
    let dummy = dummy_var
    let[@inline] level v = v.v_level
    let[@inline] pos v = v.pa
    let[@inline] neg v = v.na
    let[@inline] reason v = v.reason
    let[@inline] weight v = v.v_weight

    let[@inline] id v =v.vid
    let[@inline] level v =v.v_level
    let[@inline] idx v = v.v_idx

    let[@inline] set_level v lvl = v.v_level <- lvl
    let[@inline] set_idx v i = v.v_idx <- i
    let[@inline] set_weight v w = v.v_weight <- w

    let[@inline] in_heap v = v.v_idx >= 0

    let make (st:state) (t:formula) : var * Theory_intf.negated =
      let lit, negated = E.Form.norm t in
      try
        MF.find st.f_map lit, negated
      with Not_found ->
        let cpt_double = st.cpt_mk_var lsl 1 in
        let rec var  =
          { vid = st.cpt_mk_var;
            pa = pa;
            na = na;
            v_fields = Var_fields.empty;
            v_level = -1;
            v_idx= -1;
            v_weight = 0.;
            reason = None;
          }
        and pa =
          { var = var;
            lit = lit;
            watched = Vec.make 10 dummy_clause;
            neg = na;
            is_true = false;
            aid = cpt_double (* aid = vid*2 *) }
        and na =
          { var = var;
            lit = E.Form.neg lit;
            watched = Vec.make 10 dummy_clause;
            neg = pa;
            is_true = false;
            aid = cpt_double + 1 (* aid = vid*2+1 *) } in
        MF.add st.f_map lit var;
        st.cpt_mk_var <- st.cpt_mk_var + 1;
        Vec.push st.vars var;
        var, negated

    (* Marking helpers *)
    let[@inline] clear v =
      v.v_fields <- Var_fields.empty

    let[@inline] seen_both v =
      Var_fields.get v_field_seen_pos v.v_fields &&
      Var_fields.get v_field_seen_neg v.v_fields
  end

  module Atom = struct
    type t = atom
    let dummy = dummy_atom
    let[@inline] level a = a.var.v_level
    let[@inline] var a = a.var
    let[@inline] neg a = a.neg
    let[@inline] abs a = a.var.pa
    let[@inline] lit a = a.lit
    let[@inline] equal a b = a == b
    let[@inline] is_pos a = a == abs a
    let[@inline] compare a b = Pervasives.compare a.aid b.aid
    let[@inline] reason a = Var.reason a.var
    let[@inline] id a = a.aid
    let[@inline] is_true a = a.is_true
    let[@inline] is_false a = a.neg.is_true

    let[@inline] seen a =
      let pos = equal a (abs a) in
      if pos
      then Var_fields.get v_field_seen_pos a.var.v_fields
      else Var_fields.get v_field_seen_neg a.var.v_fields

    let[@inline] mark a =
      let pos = equal a (abs a) in
      if pos
      then a.var.v_fields <- Var_fields.set v_field_seen_pos true a.var.v_fields
      else a.var.v_fields <- Var_fields.set v_field_seen_neg true a.var.v_fields

    let[@inline] make st lit =
      let var, negated = Var.make st lit in
      match negated with
      | Theory_intf.Negated -> var.na
      | Theory_intf.Same_sign -> var.pa

    let pp fmt a = E.Form.print fmt a.lit

    let pp_a fmt v =
      if Array.length v = 0 then (
        Format.fprintf fmt "∅"
      ) else (
        pp fmt v.(0);
        if (Array.length v) > 1 then begin
          for i = 1 to (Array.length v) - 1 do
            Format.fprintf fmt " ∨ %a" pp v.(i)
          done
        end
      )

    (* Complete debug printing *)
    let sign a = if a == a.var.pa then "+" else "-"

    let debug_reason fmt = function
      | n, _ when n < 0 ->
        Format.fprintf fmt "%%"
      | n, None ->
        Format.fprintf fmt "%d" n
      | n, Some Decision ->
        Format.fprintf fmt "@@%d" n
      | n, Some Bcp c ->
        Format.fprintf fmt "->%d/%s" n (name_of_clause c)
      | n, Some Semantic ->
        Format.fprintf fmt "::%d" n

    let pp_level fmt a =
      debug_reason fmt (a.var.v_level, a.var.reason)

    let debug_value fmt a =
      if a.is_true then
        Format.fprintf fmt "T%a" pp_level a
      else if a.neg.is_true then
        Format.fprintf fmt "F%a" pp_level a
      else
        Format.fprintf fmt ""

    let debug out a =
      Format.fprintf out "%s%d[%a][@[%a@]]"
        (sign a) (a.var.vid+1) debug_value a E.Form.print a.lit

    let debug_a out vec =
      Array.iter (fun a -> Format.fprintf out "%a@ " debug a) vec
  end

  module Clause = struct
    type t = clause
    let dummy = dummy_clause

    let make =
      let n = ref 0 in
      fun ?tag ali premise ->
        let atoms = Array.of_list ali in
        let name = !n in
        incr n;
        { name;
          tag = tag;
          atoms = atoms;
          c_flags = C_fields.empty;
          activity = 0.;
          cpremise = premise;
        }

    let empty = make [] (History [])
    let name = name_of_clause
    let[@inline] equal c1 c2 = c1==c2
    let[@inline] atoms c = c.atoms
    let[@inline] atoms_l c = Array.to_list c.atoms
    let[@inline] tag c = c.tag
    let hash cl = Array.fold_left (fun i a -> Hashtbl.hash (a.aid, i)) 0 cl.atoms

    let[@inline] premise c = c.cpremise
    let[@inline] set_premise c p = c.cpremise <- p

    let[@inline] visited c = C_fields.get c_field_visited c.c_flags
    let[@inline] set_visited c b = c.c_flags <- C_fields.set c_field_visited b c.c_flags

    let[@inline] attached c = C_fields.get c_field_attached c.c_flags
    let[@inline] set_attached c b = c.c_flags <- C_fields.set c_field_attached b c.c_flags

    let[@inline] activity c = c.activity
    let[@inline] set_activity c w = c.activity <- w

    module Tbl = Hashtbl.Make(struct
        type t = clause
        let hash = hash
        let equal = equal
      end)

    let pp fmt c =
      Format.fprintf fmt "%s : %a" (name c) Atom.pp_a c.atoms

    let debug_premise out = function
      | Hyp -> Format.fprintf out "hyp"
      | Local -> Format.fprintf out "local"
      | Lemma _ -> Format.fprintf out "th_lemma"
      | History v ->
        List.iter (fun c -> Format.fprintf out "%s,@ " (name_of_clause c)) v

    let debug out ({atoms=arr; cpremise=cp;_}as c) =
      Format.fprintf out "%s@[<hov>{@[<hov>%a@]}@ cpremise={@[<hov>%a@]}@]"
        (name c) Atom.debug_a arr debug_premise cp

    let pp_dimacs fmt {atoms;_} =
      let aux fmt a =
        Array.iter (fun p ->
          Format.fprintf fmt "%s%d "
            (if p == p.var.pa then "-" else "")
            (p.var.vid+1)
        ) a
      in
      Format.fprintf fmt "%a0" aux atoms
  end

  module Formula = struct
    include E.Form
    let pp = print
  end
end[@@inline]
