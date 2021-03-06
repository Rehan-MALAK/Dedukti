open Basic
open Format
open Rule
open Term

module SS = Subst.Subst

let d_typeChecking = Debug.register_flag "TypeChecking"
let d_rule         = Debug.register_flag  "Rule"

let coc = ref false

let fail_on_unsatisfiable_constraints = ref false

type typ = term

(* ********************** ERROR MESSAGES *)

type typing_error =
  | KindIsNotTypable
  | ConvertibilityError                of term * typed_context * term * term
  | AnnotConvertibilityError           of loc * ident * typed_context * term * term
  | VariableNotFound                   of loc * ident * int * typed_context
  | SortExpected                       of term * typed_context * term
  | ProductExpected                    of term * typed_context * term
  | InexpectedKind                     of term * typed_context
  | DomainFreeLambda                   of loc
  | CannotInferTypeOfPattern           of pattern * typed_context
  | UnsatisfiableConstraints           of partially_typed_rule * (int * term * term)
  | BracketExprBoundVar                of term * typed_context
  | BracketExpectedTypeBoundVar        of term * typed_context * term
  | BracketExpectedTypeRightVar        of term * typed_context * term
  | TypingCircularity                  of loc * ident * int * typed_context * term
  | FreeVariableDependsOnBoundVariable of loc * ident * int * typed_context * term
  | NotImplementedFeature              of loc
  | Unconvertible                      of loc * term * term
  | Convertible                        of loc * term * term
  | Inhabit                            of loc * term * term

exception Typing_error of typing_error

module type S = sig
  val infer       : Signature.t -> typed_context -> term -> typ

  val check       : Signature.t -> typed_context -> term -> typ -> unit

  val checking    : Signature.t -> term -> term -> unit

  val inference   : Signature.t -> term -> typ

  val check_rule  : Signature.t -> partially_typed_rule -> SS.t * typed_rule
end

(* ********************** CONTEXT *)
module Make(R:Reduction.S) =
struct

  let get_type ctx l x n =
    try let (_,_,ty) = List.nth ctx n in Subst.shift (n+1) ty
    with Failure _ -> raise (Typing_error (VariableNotFound (l,x,n,ctx)))

  let extend_ctx a ctx = function
    | Type _ -> a::ctx
    | Kind when !coc -> a::ctx
    | ty_a ->
      let (_,_,te) = a in
      raise (Typing_error (ConvertibilityError (te, ctx, mk_Type dloc, ty_a)))

  (* ********************** TYPE CHECKING/INFERENCE FOR TERMS  *)

  let rec infer sg (ctx:typed_context) (te:term) : typ =
    Debug.(debug d_typeChecking "Inferring: %a" pp_term te);
    match te with
    | Kind -> raise (Typing_error KindIsNotTypable)
    | Type _ -> mk_Kind
    | DB (l,x,n) -> get_type ctx l x n
    | Const (l,cst) -> Signature.get_type sg l cst
    | App (f,a,args) ->
      snd (List.fold_left (check_app sg ctx) (f,infer sg ctx f) (a::args))
    | Pi (l,x,a,b) ->
      let ty_a = infer sg ctx a in
      let ctx2 = extend_ctx (l,x,a) ctx ty_a in
      let ty_b = infer sg ctx2 b in
      ( match ty_b with
        | Kind | Type _ -> ty_b
        | _ -> raise (Typing_error (SortExpected (b, ctx2, ty_b))) )
    | Lam  (l,x,Some a,b) ->
      let ty_a = infer sg ctx a in
      let ctx2 = extend_ctx (l,x,a) ctx ty_a in
      let ty_b = infer sg ctx2 b in
      ( match ty_b with
        | Kind -> raise (Typing_error (InexpectedKind (b, ctx2)))
        | _ -> mk_Pi l x a ty_b )
    | Lam  (l,_,None,_) -> raise (Typing_error (DomainFreeLambda l))

  and check sg (ctx:typed_context) (te:term) (ty_exp:typ) : unit =
    Debug.(debug d_typeChecking "Checking (%a): %a : %a"
             pp_loc (get_loc te) pp_term te pp_term ty_exp);
    match te with
    | Lam (l,x,op,b) ->
      begin
        match R.whnf sg ty_exp with
        | Pi (_,_,a,ty_b) ->
          ( match op with
            | Some a' ->
               ignore(infer sg ctx a');
               if not (R.are_convertible sg a a')
               then raise (Typing_error (ConvertibilityError ((mk_DB l x 0),ctx,a,a')))
            | _ -> ()
          );
          check sg ((l,x,a)::ctx) b ty_b
        | _ -> raise (Typing_error (ProductExpected (te,ctx,ty_exp)))
      end
    | _ ->
      let ty_inf = infer sg ctx te in
      Debug.(debug d_typeChecking "Checking convertibility: %a ~ %a"
               pp_term ty_inf pp_term ty_exp);
      if not (R.are_convertible sg ty_inf ty_exp) then
        let ty_exp' = rename_vars_with_typed_context ctx ty_exp in
        raise (Typing_error (ConvertibilityError (te,ctx,ty_exp',ty_inf)))

  and check_app sg (ctx:typed_context) (f,ty_f:term*typ) (arg:term) : term*typ =
    match R.whnf sg ty_f with
    | Pi (_,_,a,b) ->
      let _ = check sg ctx arg a in (mk_App f arg [], Subst.subst b arg )
    | _ -> raise (Typing_error ( ProductExpected (f,ctx,ty_f)))

  let inference sg (te:term) : typ = infer sg [] te

  let checking sg (te:term) (ty:term) : unit =
    let _ = infer sg [] ty in
    check sg [] te ty

  (* **** PSEUDO UNIFICATION ********************** *)

  let rec add_to_list q lst args1 args2 =
    match args1,args2 with
    | [], [] -> lst
    | a1::args1, a2::args2 -> add_to_list q ((q,a1,a2)::lst) args1 args2
    | _, _ -> raise (Invalid_argument "add_to_list")

let safe_add_to_list q lst args1 args2 =
  try Some (add_to_list q lst args1 args2)
  with Invalid_argument _ -> None

let unshift_reduce sg q t =
  try Some (Subst.unshift q t)
  with Subst.UnshiftExn ->
    ( try Some (Subst.unshift q (R.snf sg t))
      with Subst.UnshiftExn -> None )

(** Under [d] lambdas, checks whether term [te] *must* contain an occurence
    of any variable that satisfies the given predicate [p],
    *even when substituted or reduced*.
    This check make no assumption on the rewrite system or possible substitution
    - any definable symbol are "safe" as they may reduce to a term where no variable occur
    - any applied meta variable (DB index > [d]) are "safe" as they may be
      substituted and reduce to a term where no variable occur
    Raises VarSurelyOccurs if the term [te] *surely* contains an occurence of one
    of the [vars].
 *)
let sure_occur_check sg (d:int) (p:int -> bool) (te:term) : bool =
  let exception VarSurelyOccurs in
  let rec aux = function
    | [] -> ()
    | (k,t) :: tl -> (* k counts the number of local lambda abstractions *)
      match t with
      | Kind | Type _ | Const _ -> aux tl
      | Pi  (_,_,     a,b) -> aux ((k,a)::(k+1,b)::tl)
      | Lam (_,_,None  ,b) -> aux (       (k+1,b)::tl)
      | Lam (_,_,Some a,b) -> aux ((k,a)::(k+1,b)::tl)
      | DB (_,_,n) -> if n >= k && p (n-k) then raise VarSurelyOccurs else aux tl
      | App (f,a,args) ->
        begin
          match f with
          | DB (_,_,n) when n >= k + d -> (* a matching variable *)
            if p (n-k) then raise VarSurelyOccurs else aux tl
          | DB (_,_,n) when n < k + d -> (* a locally bound variable *)
            if n >= k && p (n-k)
            then raise VarSurelyOccurs
            else aux ( (k, a):: (List.map (fun t -> (k,t)) args) @ tl)
          | Const (l,cst) when Signature.is_injective sg l cst ->
            (  aux ( (k, a):: (List.map (fun t -> (k,t)) args) @ tl) )
          | _ -> aux tl
          (* Default case encompasses:
             - Meta variables: DB(_,_,n) with n >= k + d
             - Definable symbols
             - Lambdas (FIXME: when can this happen ?)
             - Illegal applications  *)
        end
  in
  try aux [(0,te)]; false
  with VarSurelyOccurs -> true

(** Under [d] lambdas, gather all free variables that are *surely*
    contained in term [te]. That is to say term [te] will contain
    an occurence of these variables *even when substituted or reduced*.
    This check make no assumption on the rewrite system or possible substitutions
    - applied definable symbols *surely* contain no variable as they may
      reduce to terms where their arguments are erased
    - applied meta variable (DB index > [d]) *surely* contain no variable as they
      may be substituted and reduce to a term where their arguments are erased
    Sets the indices of *surely* contained variables to [true] in the [vars]
    boolean array which is expected to be of size (at least) [d].
 *)
let gather_free_vars (d:int) (terms:term list) : bool array =
  let vars = Array.make d false in
  let rec aux = function
    | [] -> ()
    | (k,t) :: tl -> (* k counts the number of local lambda abstractions *)
      match t with
      | DB (_,_,n) -> (if n >= k && n < k + d then vars.(n-k) <- true); aux tl
      | Pi  (_,_,     a,b) -> aux ((k,a)::(k+1,b)::tl)
      | Lam (_,_,None  ,b) -> aux (       (k+1,b)::tl)
      | Lam (_,_,Some a,b) -> aux ((k,a)::(k+1,b)::tl)
      | App (f,a,args)     -> aux ((k,f)::(k,a):: (List.map (fun t -> (k,t)) args) @ tl)
      | _ -> aux tl
  in aux (List.map (fun t -> (0,t)) terms); vars

let rec pseudo_u sg (fail: int*term*term-> unit) (sigma:SS.t) : (int*term*term) list -> SS.t = function
  | [] -> sigma
  | (q,t1,t2)::lst ->
    begin
      let t1' = R.whnf sg (SS.apply sigma q t1) in
      let t2' = R.whnf sg (SS.apply sigma q t2) in
      let keepon () = pseudo_u sg fail sigma lst in
      if term_eq t1' t2' then keepon ()
      else
        let warn () = fail (q,t1,t2); keepon () in
        match t1', t2' with
        | Kind, Kind | Type _, Type _       -> assert false (* Equal terms *)
        | DB (_,_,n), DB (_,_,n') when n=n' -> assert false (* Equal terms *)
        | _, Kind | Kind, _ |_, Type _ | Type _, _ -> warn ()

        | Pi (_,_,a,b), Pi (_,_,a',b') ->
          pseudo_u sg fail sigma ((q,a,a')::(q+1,b,b')::lst)
        | Lam (_,_,_,b), Lam (_,_,_,b') ->
          pseudo_u sg fail sigma ((q+1,b,b')::lst)

        (* Potentially eta-equivalent terms *)
        | Lam (_,i,_,b), a when !Reduction.eta ->
          let b' = mk_App (Subst.shift 1 a) (mk_DB dloc i 0) [] in
          pseudo_u sg fail sigma ((q+1,b,b')::lst)
        | a, Lam (_,i,_,b) when !Reduction.eta ->
          let b' = mk_App (Subst.shift 1 a) (mk_DB dloc i 0) [] in
          pseudo_u sg fail sigma ((q+1,b,b')::lst)

        (* A definable symbol is only be convertible with closed terms *)
        | Const (l,cst), t when not (Signature.is_injective sg l cst) ->
          if sure_occur_check sg q (fun k -> k <= q) t then warn() else keepon()
        | t, Const (l,cst) when not (Signature.is_injective sg l cst) ->
          if sure_occur_check sg q (fun k -> k <= q) t then warn() else keepon()

        (* X = Y :  map either X to Y or Y to X *)
        | DB (l1,x1,n1), DB (l2,x2,n2) when n1>=q && n2>=q ->
           let (n,t) = if n1<n2
                       then (n1,mk_DB l2 x2 (n2-q))
                       else (n2,mk_DB l1 x1 (n1-q)) in
           pseudo_u sg fail (SS.add sigma (n-q) t) lst

        (* X = t :
           1) make sure that t is possibly closed and without occurence of X
           2) if by chance t already is so, then map X to t
           3) otherwise drop the constraint *)
        | DB (_,_,n), t when n>=q ->
          if sure_occur_check sg q (fun k -> k <= q || k = n) t
          then warn()
          else begin
            match unshift_reduce sg q t with
            | None    -> keepon()
            | Some ut ->
              let n' = n-q in
              let t' = if Subst.occurs n' ut then ut else R.snf sg ut in
              if Subst.occurs n' t' then warn()
              else pseudo_u sg fail (SS.add sigma n' t') lst
          end
        | t, DB (_,_,n) when n>=q ->
          if sure_occur_check sg q (fun k -> k <= q || k = n) t
          then warn()
          else begin
            match unshift_reduce sg q t with
            | None    -> keepon()
            | Some ut ->
              let n' = n-q in
              let t' = if Subst.occurs n' ut then ut else R.snf sg ut in
              if Subst.occurs n' t' then warn()
              else pseudo_u sg fail (SS.add sigma n' t') lst
          end

        (* f t1 ... tn    /    X t1 ... tn  =  u
           1) Gather all free variables in t1 ... tn
           2) Make sure u only relies on these variables
        *)
        | App (DB (_,_,n),a,args), t when n >= q ->
          let occs = gather_free_vars q (a::args) in
          if sure_occur_check sg q (fun k -> k < q && not occs.(k)) t then warn() else keepon()
        | t, App (DB (_,_,n),a,args) when n >= q ->
          let occs = gather_free_vars q (a::args) in
          if sure_occur_check sg q (fun k -> k < q && not occs.(k)) t then warn() else keepon()
        | App (Const (l,cst),a,args), t when not (Signature.is_injective sg l cst) ->
          let occs = gather_free_vars q (a::args) in
          if sure_occur_check sg q (fun k -> k < q && not occs.(k)) t then warn() else keepon()
        | t, App (Const (l,cst),a,args) when not (Signature.is_injective sg l cst) ->
          let occs = gather_free_vars q (a::args) in
          if sure_occur_check sg q (fun k -> k < q && not occs.(k)) t then warn() else keepon()

        | App (f,a,args), App (f',a',args') ->
          (* f = Kind | Type | DB n when n<q | Pi _
           * | Const name when (is_static name) *)
          begin
            match safe_add_to_list q lst args args' with
            | None -> warn () (* Different number of arguments. *)
            | Some lst2 -> pseudo_u sg fail sigma ((q,f,f')::(q,a,a')::lst2)
          end

        | _, _ -> warn ()
    end

(* **** TYPE CHECKING/INFERENCE FOR PATTERNS ******************************** *)

type constraints = (int * term * term) list
type context2    = (loc * ident * typ) LList.t

(* Partial Context *)

type partial_context =
  {
    padding : int;     (* expected size   *)
    pctx    : context2; (* partial context *)
    bracket : bool
  }

let pc_make (ctx:partially_typed_context) : partial_context =
  let size = List.length ctx in
  assert ( size >= 0 );
  { padding=size; pctx=LList.nil; bracket=false }

let pc_in (delta:partial_context) (n:int) : bool = n >= delta.padding

let pc_get (delta:partial_context) (n:int) : term =
  let (_,_,ty) = LList.nth delta.pctx (n-delta.padding)
  in Subst.shift (n+1) ty

let pc_add (delta:partial_context) (n:int) (l:loc) (id:ident) (ty0:typ) : partial_context =
  assert ( n == delta.padding-1 && n >= 0 );
  let ty = Subst.unshift (n+1) ty0 in
  { padding = delta.padding - 1;
    pctx = LList.cons (l,id,ty) delta.pctx;
    bracket = false }

let pc_to_context (delta:partial_context) : typed_context = LList.lst delta.pctx

let pc_to_context_wp (delta:partial_context) : typed_context =
  let dummy = (dloc, dmark, mk_DB dloc dmark (-1)) in
  let rec aux lst = function 0 -> lst | n -> aux (dummy::lst) (n-1) in
  aux (pc_to_context delta) delta.padding

(* let pp_pcontext fmt delta =
 *   let lst = List.rev (LList.lst delta.pctx) in
 *   List.iteri (fun i (_,x,ty) -> fprintf fmt "%a[%i]:%a\n" pp_ident x i pp_term ty) lst;
 *   for i = 0 to delta.padding -1 do
 *     fprintf fmt "?[%i]:?\n" (i+LList.len delta.pctx)
 *   done *)

(* *** *)

let get_last =
  let rec aux acc = function
  | [] -> assert false
  | [a] -> (List.rev acc, a)
  | hd::tl -> aux (hd::acc) tl in
  aux []

let unshift_n sg n te =
  try Subst.unshift n te
  with Subst.UnshiftExn -> Subst.unshift n (R.snf sg te)

let rec infer_pattern sg (delta:partial_context) (sigma:context2)
    (lst:constraints) (pat:pattern) : typ * partial_context * constraints =
  match pat with
  | Pattern (l,cst,args) ->
    let (_,_,ty,delta2,lst2) = List.fold_left (infer_pattern_aux sg)
        ( sigma, mk_Const l cst , Signature.get_type sg l cst , delta , lst ) args
    in (ty,delta2,lst2)
  | Var (l,x,n,args) when n < LList.len sigma ->
    let (_,_,ty,delta2,lst2) = List.fold_left (infer_pattern_aux sg)
        ( sigma, mk_DB l x n, get_type (LList.lst sigma) l x n , delta , lst ) args
    in (ty,delta2,lst2)
  | Var _ | Brackets _ | Lambda _ ->
    let ctx = (LList.lst sigma)@(pc_to_context_wp delta) in
    raise (Typing_error (CannotInferTypeOfPattern (pat,ctx)))

and infer_pattern_aux sg
    (sigma,f,ty_f,delta,lst : context2*term*typ*partial_context*constraints)
    (arg:pattern)           : context2*term*typ*partial_context*constraints =
  match R.whnf sg ty_f with
  | Pi (_,_,a,b) ->
    let (delta2,lst2) = check_pattern sg delta sigma a lst arg in
    let arg' = pattern_to_term arg in
    ( sigma, Term.mk_App f arg' [], Subst.subst b arg', delta2 , lst2 )
  | ty_f ->
    let ctx = (LList.lst sigma)@(pc_to_context_wp delta) in
    raise (Typing_error (ProductExpected (f,ctx,ty_f)))

and check_pattern sg (delta:partial_context) (sigma:context2) (exp_ty:typ)
    (lst:constraints) (pat:pattern) : partial_context * constraints =
  Debug.(debug d_rule "Checking pattern %a:%a" pp_pattern pat pp_term exp_ty);
  let ctx () = (LList.lst sigma)@(pc_to_context_wp delta) in
  match pat with
  | Lambda (l,x,p) ->
    begin
      match R.whnf sg exp_ty with
      | Pi (_,_,a,b) -> check_pattern sg delta (LList.cons (l,x,a) sigma) b lst p
      | _            -> raise (Typing_error ( ProductExpected (pattern_to_term pat,ctx (),exp_ty)))
    end
  | Brackets te ->
    let _ =
      try Subst.unshift (LList.len sigma) te
      with Subst.UnshiftExn -> raise (Typing_error (BracketExprBoundVar (te,ctx())))
    in
    let exp_ty2 =
      try unshift_n sg (LList.len sigma) exp_ty
      with Subst.UnshiftExn ->
        raise (Typing_error (BracketExpectedTypeBoundVar (te,ctx(),exp_ty)))
    in
    let _ =
      try unshift_n sg delta.padding exp_ty2
      with Subst.UnshiftExn ->
        raise (Typing_error (BracketExpectedTypeRightVar (te,ctx(),exp_ty)))
    in
    ( {delta with bracket = true}, lst)
  | Var (l,x,n,[]) when n >= LList.len sigma ->
    begin
      let k = LList.len sigma in
      (* Bracket may introduce circularity (variable's expected type depending on itself *)
      if delta.bracket && Subst.occurs (n-k) exp_ty
      then raise (Typing_error (TypingCircularity(l,x,n,ctx(),exp_ty)));
      if pc_in delta (n-k)
      then
        let inf_ty = Subst.shift k (pc_get delta (n-k)) in
        ( delta, (k,inf_ty,exp_ty)::lst )
      else
        ( try ( pc_add delta (n-k) l x (unshift_n sg k exp_ty), lst )
          with Subst.UnshiftExn ->
            raise (Typing_error (FreeVariableDependsOnBoundVariable (l,x,n,ctx(),exp_ty))) )
    end
  | Var (l,x,n,args) when n >= LList.len sigma ->
    begin
      let k = LList.len sigma in
      (* Bracket may introduce circularity (variable's expected type depending on itself *)
      if delta.bracket && Subst.occurs (n-k) exp_ty
      then raise (Typing_error (TypingCircularity(l,x,n,ctx(),exp_ty)));
      let (args2, last) = get_last args in
      match last with
      | Var (l2,x2,n2,[]) ->
        check_pattern sg delta sigma
          (mk_Pi l2 x2 (get_type (LList.lst sigma) l2 x2 n2) (Subst.subst_n n2 x2 exp_ty) )
          lst (Var(l,x,n,args2))
      | _ -> raise (Typing_error (CannotInferTypeOfPattern (pat,ctx ()))) (* not a pattern *)
    end
  | _ ->
    begin
      let (inf_ty,delta2,lst2) = infer_pattern sg delta sigma lst pat in
      let q = LList.len sigma in
      ( delta2 , (q,inf_ty,exp_ty)::lst2 )
    end

(* ************************************************************************** *)

let pp_context_inline fmt ctx =
  pp_list ", "
    (fun fmt (_,x,ty) -> fprintf fmt "%a: %a" pp_ident x pp_term ty )
    fmt (List.rev ctx)

let subst_context (sub:SS.t) (ctx:typed_context) : typed_context =
  if SS.is_identity sub then ctx
  else
    let apply_subst i (l,x,ty) = (l,x,Subst.apply_subst (SS.subst2 sub i) 0 ty) in
    List.mapi apply_subst ctx

let check_type_annotations sg sub typed_ctx annot_ctx =
  Debug.(debug d_rule "Typechecking type annotations");
  let rec aux ctx depth ctx1 ctx2 =
    match ctx1, ctx2 with
    | (l,x,ty)::ctx1' , (_,_,ty')::ctx2' ->
      begin
        match ty' with
        | None -> ()
        | Some ty' ->
          Debug.(debug d_typeChecking "Checking type annotation (%a): %a ~ %a"
                   pp_loc l pp_term ty pp_term ty');
          if not (R.are_convertible sg ty ty')
          then
            let ty2  = SS.apply sub 0 (Subst.shift depth ty ) in
            let ty2' = SS.apply sub 0 (Subst.shift depth ty') in
            if not (R.are_convertible sg ty2 ty2')
            then raise (Typing_error (AnnotConvertibilityError (l,x,ctx,ty',ty)))
      end;
      aux ((l,x,ty)::ctx) (depth+1) ctx1' ctx2'
    | [], [] -> ()
    | _ -> assert false
  in aux [] 1 typed_ctx annot_ctx

let check_rule sg (rule:partially_typed_rule) : SS.t * typed_rule =
  Debug.(debug d_rule "Inferring variables type and constraints from LHS");
  let fail = if !fail_on_unsatisfiable_constraints
    then (fun x -> raise (Typing_error (UnsatisfiableConstraints (rule,x))))
    else (fun (q,t1,t2) ->
        Debug.(debug d_warn "At %a: unsatisfiable constraint: %a ~ %a%s"
                 pp_loc (get_loc_rule rule)
                 pp_term t1 pp_term t2
                 (if q > 0 then Format.sprintf " (under %i abstractions)" q else ""))) in
  let delta = pc_make rule.ctx in
  let (ty_le,delta,lst) = infer_pattern sg delta LList.nil [] rule.pat in
  assert ( delta.padding == 0 );
  let sub = SS.mk_idempotent (pseudo_u sg fail SS.identity lst) in
  let ri2    = SS.apply sub 0 rule.rhs in
  let ty_le2 = SS.apply sub 0 ty_le    in
  let ctx = LList.lst delta.pctx in
  let ctx2 =
    try subst_context sub ctx
    with Subst.UnshiftExn -> (* TODO make Dedukti handle this case *)
      Debug.(
        debug d_rule "Failed to infer a typing context for the rule:\n%a"
          pp_part_typed_rule rule;
        let ctx_name n = let _,name,_ = List.nth ctx n in name in
        debug d_rule "Tried inferred typing substitution: %a" (SS.pp ctx_name) sub);
      raise (Typing_error (NotImplementedFeature (get_loc_pat rule.pat) ) )
  in
  Debug.(debug d_rule "Typechecking rule");
  check sg ctx2 ri2 ty_le2;
  check_type_annotations sg sub ctx2 rule.ctx;
  Debug.(debug d_rule "Fully checked rule:@.[ %a ] %a --> %a"
           pp_context_inline ctx2 pp_pattern rule.pat pp_term ri2);

  sub,
  { name = rule.name;
    ctx = ctx2;
    pat = rule.pat;
    rhs = rule.rhs
  }

end

module Default = Make(Reduction.Default)
