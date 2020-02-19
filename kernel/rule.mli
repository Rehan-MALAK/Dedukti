open Basic
open Term

(** Rewrite rules *)

(** {2 Patterns} *)

(** Basic representation of pattern *)
type pattern =
  | Var      of loc * ident * int * pattern list (** Applied DB variable *)
  | Pattern  of loc * name * pattern list        (** Applied constant    *)
  | Lambda   of loc * ident * pattern            (** Lambda abstraction  *)
  | Brackets of term                             (** Bracket of a term   *)

val get_loc_pat : pattern -> loc

val pattern_to_term : pattern -> term

(** Efficient representation for well-formed linear Miller pattern *)
type wf_pattern =
  | LJoker
  | LVar      of ident * int * int list         (** Applied Miller variable *)
  | LLambda   of ident * wf_pattern             (** Lambda abstraction      *)
  | LPattern  of name * wf_pattern array        (** Applied constant        *)
  | LBoundVar of ident * int * wf_pattern array (** Locally bound variable  *)

(** {2 Linearization} *)

(** [constr] is the type of constraints.
    They are generated by the function check_patterns. *)
type constr =
  | Linearity of int * int  (** DB indices [i] and [j] of the pattern should be convertible *)
  | Bracket   of int * term (** DB indices [i] should be convertible to the term [te] *)

(** {2 Rewrite Rules} *)

type rule_name =
  | Beta
  | Delta of name
  (** Rules associated to the definition of a constant *)
  | Gamma of bool * name
  (** Rules of lambda pi modulo. The first parameter indicates whether
      the name of the rule has been given by the user. *)

val rule_name_eq : rule_name -> rule_name -> bool

type 'a rule =
  {
    name: rule_name;
    ctx : 'a context;
    pat : pattern;
    rhs : term
  }
(** A rule is formed with
    - a name
    - an annotated context
    - a left-hand side pattern
    - a right-hand side term
*)

val get_loc_rule : 'a rule -> loc

type partially_typed_rule = term option rule
(** Rule where context is partially annotated with types *)

type typed_rule = term rule
(** Rule where context is fully annotated with types *)

type arity_rule = int rule
(** Rule where context is annotated with variable arities *)

(** {2 Errors} *)

type rule_error =
  | BoundVariableExpected          of loc * pattern
  | DistinctBoundVariablesExpected of loc * ident
  | VariableBoundOutsideTheGuard   of loc * term
  | UnboundVariable                of loc * ident * pattern
  | AVariableIsNotAPattern         of loc * ident
  | NonLinearNonEqArguments        of loc * ident
  | NotEnoughArguments             of loc * ident * int * int * int
  | NonLinearRule                  of loc * rule_name

exception Rule_error of rule_error

(** {2 Rule infos} *)

type rule_infos =
  {
    l           : loc;
    (** location of the rule *)
    name        : rule_name;
    (** name of the rule *)
    cst         : name;
    (** name of the pattern constant *)
    args        : pattern list;
    (** arguments list of the pattern constant *)
    rhs         : term;
    (** right hand side of the rule *)
    ctx_size    : int;
    (** size of the context of the non-linear version of the rule *)
    esize       : int;
    (** size of the context of the linearized, bracket free version of the rule *)
    pats        : wf_pattern array;
    (** free patterns without constraint *)
    arity       : int array;
    (** arities of context variables *)
    constraints : constr list
    (** constraints generated from the pattern to the free pattern *)
  }

val infer_rule_context : rule_infos -> arity_context
(** Extracts arity context from a rule info *)

val pattern_of_rule_infos : rule_infos -> pattern
(** Extracts LHS pattern from a rule info *)

val to_rule_infos : 'a rule -> rule_infos
(** Converts any rule (typed or untyped) to rule_infos *)

val untyped_rule_of_rule_infos : rule_infos -> arity_rule
(** Converts rule_infos representation to a rule where
    the context is annotated with the variables' arity *)

(** {2 Printing} *)

val pp_rule_name       : rule_name       printer
val pp_untyped_rule    : 'a rule         printer
val pp_typed_rule      : typed_rule      printer
val pp_part_typed_rule : partially_typed_rule printer
val pp_pattern         : pattern         printer
val pp_wf_pattern      : wf_pattern      printer
val pp_rule_infos      : rule_infos      printer

val check_arity : rule_infos -> unit

val check_linearity : rule_infos -> unit
