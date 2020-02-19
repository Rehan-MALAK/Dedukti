open Kernel
open Basic
open Term
open Rule
open Typing
open Parsers


exception DebugFlagNotRecognized of char

let set_debug_mode =
  String.iter (function
      | 'q' -> Debug.disable_flag Debug.d_warn
      | 'n' -> Debug.enable_flag  Debug.d_notice
      | 'o' -> Debug.enable_flag  Signature.d_module
      | 'c' -> Debug.enable_flag  Confluence.d_confluence
      | 'u' -> Debug.enable_flag  Typing.d_rule
      | 't' -> Debug.enable_flag  Typing.d_typeChecking
      | 'r' -> Debug.enable_flag  Reduction.d_reduce
      | 'm' -> Debug.enable_flag  Matching.d_matching
      | c -> raise (DebugFlagNotRecognized c)
    )

type t =
  {
    input : Parser.t;
    sg    : Signature.t;
    red   : (module Reduction.S);
    typer : (module Typing.S)
  }

let dummy ?md () =
  let dummy_md = match md with
    | None    -> Basic.mk_mident ""
    | Some(m) -> m
  in
  let dummy_sig =
    Signature.make dummy_md (fun _ _ -> "")
  in
  { input = Parser.input_from_string dummy_md ""
  ; sg = dummy_sig
  ; red = (module Reduction.Default)
  ; typer = (module Typing.Default) }

exception Env_error of t * loc * exn

let get_input env = env.input

let check_arity = ref true

let check_ll = ref false

let init input =
  let sg =  Signature.make (Parser.md_of_input input) Files.find_object_file in
  let red : (module Reduction.S) = (module Reduction.Default) in
  let typer : (module Typing.S) = (module Typing.Default) in
  {input; sg;red;typer}

let set_reduction_engine env (module R:Reduction.S) =
  let red = (module R:Reduction.S) in
  let typer = (module Typing.Make(R):Typing.S) in
  {env with red;typer}

let get_reduction_engine env = env.red

let get_name env = Signature.get_name env.sg

let get_filename env =
  match Parser.file_of_input env.input with
  | None -> "<not a file>"
  | Some f -> f

let get_signature env = env.sg

let get_printer env : (module Pp.Printer) =
  (module Pp.Make(struct let get_name () = get_name env end))

module HName = Hashtbl.Make(
  struct
    type t    = name
    let equal = name_eq
    let hash  = Hashtbl.hash
  end )

let get_symbols env =
  let table = HName.create 11 in
  Signature.iter_symbols (fun md id -> HName.add table (mk_name md id)) env.sg;
  table

let get_type env lc cst =
  Signature.get_type env.sg lc cst

let get_dtree env lc cst =
  Signature.get_dtree env.sg lc cst

let export env =
  let file = Files.object_file_of_input env.input in
  let oc = open_out file in
  Signature.export env.sg oc; close_out oc

let import env lc md =
  Signature.import env.sg lc md

let _declare env lc (id:ident) scope st ty : unit =
  let (module T) = env.typer in
  match T.inference env.sg ty with
  | Kind | Type _ -> Signature.add_declaration env.sg lc id scope st ty
  | s -> raise (Typing.Typing_error (Typing.SortExpected (ty,[],s)))

let is_injective env lc cst = Signature.is_injective env.sg lc cst

let is_static env lc cst = Signature.is_static env.sg lc cst

let _add_rules env rs =
  let ris = List.map Rule.to_rule_infos rs in
  if !check_arity then List.iter (Rule.check_arity) ris;
  if !check_ll    then List.iter (Rule.check_linearity) ris;
  Signature.add_rules env.sg ris

let _define env lc (id:ident) (scope:Signature.scope) (opaque:bool) (te:term) (ty_opt:Typing.typ option) : unit =
  let (module T) = env.typer in
  let ty = match ty_opt with
    | None -> T.inference env.sg te
    | Some ty -> T.checking env.sg te ty; ty
  in
  match ty with
  | Kind -> raise @@ Typing_error (InexpectedKind (te,[]))
  | _ ->
    if opaque then Signature.add_declaration env.sg lc id scope Signature.Static ty
    else
      let _ = Signature.add_declaration env.sg lc id scope Signature.Definable ty in
      let cst = mk_name (get_name env) id in
      let rule =
        { name= Delta(cst) ;
          ctx = [] ;
          pat = Pattern(lc, cst, []);
          rhs = te ;
        }
      in
      _add_rules env [rule]

let declare env lc id scope st ty : unit =
  _declare env lc id scope st ty

let define env lc id scope op te ty_opt : unit =
  _define env lc id scope op te ty_opt

let add_rules env (rules: partially_typed_rule list) : (Subst.Subst.t * typed_rule) list =
  let (module T) = env.typer in
  let rs2 = List.map (T.check_rule env.sg) rules in
  _add_rules env rules;
  rs2

let infer env ?ctx:(ctx=[]) te =
  let (module T) = env.typer in
  let ty = T.infer env.sg ctx te in
  (* We only verify that [ty] itself has a type (that we immediately
     throw away) if [ty] is not [Kind], because [Kind] does not have a
     type, but we still want [infer ctx Type] to produce [Kind] *)
  if ty <> mk_Kind then
    ignore(T.infer env.sg ctx ty);
  ty

let check env ?ctx:(ctx=[]) te ty =
  let (module T) = env.typer in
  T.check env.sg ctx te ty

let _unsafe_reduction env red te =
  let (module R) = env.red in
  R.reduction red env.sg te

let _reduction env ctx red te =
  (* This is a safe reduction, so we check that [te] has a type
     before attempting to normalize it, but we only do so if [te]
     is not [Kind], because [Kind] does not have a type, but we
     still want to be able to reduce it *)
  let (module T) = env.typer in
  if te <> mk_Kind then
    ignore(T.infer env.sg ctx te);
  _unsafe_reduction env red te

let reduction env ?ctx:(ctx=[]) ?red:(red=Reduction.default_cfg) te =
  _reduction env ctx red te

let unsafe_reduction env ?red:(red=Reduction.default_cfg) te =
  _unsafe_reduction env red te

let are_convertible env ?ctx:(ctx=[]) te1 te2 =
  let (module T) = env.typer in
  let (module R) = env.red in
  let ty1 = T.infer env.sg ctx te1 in
  let ty2 = T.infer env.sg ctx te2 in
  R.are_convertible env.sg ty1 ty2 &&
  R.are_convertible env.sg te1 te2

let errors_in_snf = ref false

let fail_env_error : t -> Basic.loc -> exn -> 'a = fun env lc exn ->
  let snf env t    = if !errors_in_snf then unsafe_reduction env t else t in
  let file         = get_filename env in
  let code, lc,msg = Errors.string_of_exception ~red:(snf env) lc exn in
  Errors.fail_exit ~file ~code:(string_of_int code) (Some lc) "%s" msg
