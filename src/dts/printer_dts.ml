open Format
open Dts_ast

module SSet = Set.Make(String)

let rec list ?(sep="") f fmt = function
  | [x] ->
      fprintf fmt "%a"
        f x
  | x::xs ->
      fprintf fmt "%a%s@,%a"
        f x
        sep
        (list ~sep f) xs
  | [] -> ()

let rec list_ ?(sep="") f fmt = function
  | [x] ->
      fprintf fmt "%a%s"
        f x
        sep
  | x::xs ->
      fprintf fmt "%a%s@,%a"
        f x
        sep
        (list_ ~sep f) xs
  | [] -> ()

let rec _list ?(sep="") f fmt = function
  | [x] ->
      fprintf fmt "@,%a%s"
        f x
        sep
  | x::xs ->
      fprintf fmt "@,%a%s%a"
        f x
        sep
        (_list ~sep f) xs
  | [] -> ()

let non_empty wrapper f fmt = function
  | [] -> ()
  | list -> fprintf fmt wrapper f list

let opt f fmt = function
  | None -> ()
  | Some x -> f fmt x

(* eventually make this assert false *)


let fail_on_todo = true


let todo fmt =
    assert (not fail_on_todo);
    fprintf fmt "@[%s@]"
      "#######"


(* generate_mangled_name generates a new name for an inner level
   module so that it can be moved to global scope without any
   collisions of names with any other module definition.
*)
let generate_mangled_name name = function
  | "" -> name
  | prefix -> String.concat "___" [prefix; name]

(* inverse of generate_mangled_name *)
let clean_mangled_name mangled_name =
  Str.global_substitute (Str.regexp ".*___") (fun _ -> "") mangled_name

(* get_modules_in_scope computes the list of modules which are
   declared int he cuurent scope. In particular we shall use it to
   find a list of modules in global scope.

   declare module M {
       export class A extends B implements C { }
   }

   declare module N {
       var x : M.A
   }

   For the above d.ts file, the function will return the following
   list -> "M" :: "N" :: []

   In case of nested modules, it does more. It prepends a prefix
   which is names of its ancestors separated by "____".



   declare module M {
       declare module N {
           declare module P {

           }
           declare module Q {

           }
       }
   }

   when called for the body of module N, the function will return the
   following list --> "M___N___P" :: "M___N___Q" :: []
*)

let rec get_modules_in_scope acc prefix = function
  | [] -> acc
  | x :: xs ->
    extract_module (get_modules_in_scope acc prefix xs) prefix x

and extract_module acc prefix = Statement.(function
  | _, ModuleDeclaration { Module.id; _; } ->
    (get_name prefix id) :: acc
  | _ -> acc
)

and get_name prefix = function
  | _ , { IdPath.ids; _} -> append_name prefix ids

and append_name prefix = function
  | [x] -> id_name prefix x
  | _ -> failwith
    "FLow only supports module declaration with one identifier"

and id_name prefix = function
  | _, { Identifier.name; _ } -> generate_mangled_name name prefix

(* get_modules_used computes a list of possible use of modules in the
   given list of statements. What it does is find all instances of
   object notation and enlist them. For example consider the
   following code:

   declare module M {
       export class A extends B implements C { }
   }

   declare module O {
       export class D {}
   }

   declare module N {
       var x : M.A
       var y : W.A
       var z : O.D
   }

   For the above .d.ts file, get_modules_used will return
   "M" :: "W" :: "O" :: [] when ran on the body of "module N"
   However, we can see that only "W" might not be a reference to a
   module, possibly "W" is an object defined in another file.
*)

let rec get_modules_used = function
  | [] -> SSet.empty
  | x :: xs ->
    module_used_statement (get_modules_used xs) x

(* modules_used_statement walks the AST of a given statement to see
   if it contains any node in object notation.

   TODO: Currently it only considers the case where object notation is
   present in the type annotation of a variable declaration. Need to
   cover the rest of the cases like:

   export class P extends M.Q { }

   etc.

   Note: All the child modules are by default imported by the
   parent. This is done so that they are accessbile in through the
   parent module via dot notation.

   Eg.
   declare module R {
       module T {
           export class E { }
       }
   }

   converts to
   declare module R {
     declare var T: $Exports<'R___T'>;
   }
   declare module R___T {
     declare class E {

     }
   }

   So that we can access class E as R.T.E
*)
and module_used_statement acc = Statement.(function
  | _, VariableDeclaration { VariableDeclaration.
      declarations; _
    } -> VariableDeclaration.(
      match declarations with
      | [(_, {Declarator.id; _})] ->
        module_used_pattern acc id
      | _ -> failwith "Only single declarator handled currently"
    )
  | _, ModuleDeclaration { Module.id; body; } ->
    SSet.add (get_name "" id) acc
  | _, ExportAssignment id -> (match id with
    | _, {Identifier. name; _} -> SSet.add name acc
  )
  | _ -> acc
)

and module_used_pattern acc = Pattern.(function
  | _, Identifier id -> module_used_id acc id
  | _ -> failwith "Only identifier allowed in variable declaration"
)

and module_used_id acc = function
  | _, { Identifier. typeAnnotation; _ } ->
      match typeAnnotation with
      | None -> acc
      | Some x -> module_used_type acc x

and module_used_type acc = Type.(function
  | _, Generic t -> module_used_generic acc t
  | _ -> acc
)

and module_used_generic acc = Type.(function
  | { Generic.id; _ } -> match id with
    | _, {IdPath.ids; _} -> module_used_ids acc ids
)

and module_used_ids acc = function
  | x :: xs ->  ( match x with
    | _, {Identifier. name; _ } -> SSet.add name acc
  )
  | _ -> acc



(*
  get_modules_to_import returns a list of modules that need to be
  imported. An element of this list is a tuple of two strings A and
  B. A refers to the name by which the module is to be referred to in the
  current scope and B refers to the name to which the module is be
  referred to in the global scope.
*)
let get_modules_to_import scope set =
  (* find_module matches name of a module with all the modules in
     scope by stripping of the prefix *)
  let rec find_module name = function
    | [] -> None
    | x :: xs ->
      if (clean_mangled_name x) = name
      then Some (name, x)
      else find_module name xs
  and fold_intermediate scope name acc =
    match (find_module name scope) with
    | None -> acc
    | Some x -> x :: acc
  in
  SSet.fold (fold_intermediate scope) set []



(*
  The following two functions filter out module and not_module
  statements from a list of statements respectively.
*)
let rec filter_modules prefix scope = Statement.(function
  | [] -> []
  |  x :: xs -> match x with
    | _, ModuleDeclaration _ ->
      (prefix, scope, x) :: (filter_modules prefix scope xs)
    | _ -> filter_modules prefix scope xs
)

let rec filter_not_modules = Statement.(function
  | [] -> []
  |  x :: xs -> match x with
    | _, ModuleDeclaration _ -> filter_not_modules xs
    | _ -> x :: (filter_not_modules xs)
)

(*
  Find a list of modules declared within the current module. If you
  only consider the module nodes in the AST then, this is just the
  find_child function of a tree.
*)
let find_child_modules acc prefix scope = Statement.(function
  | _, ModuleDeclaration { Module.id; body; } ->
    let new_prefix = get_name prefix id in
    let new_scope = get_modules_in_scope scope new_prefix body in
    List.append (filter_modules new_prefix new_scope body) acc
  | _ -> failwith
    "Unexpected statement. A module declaration was expected"
)

(*
  To handle flatten nested modules, we decopes the AST into modules
  and not_modules component. Note that the modules will form a tree
  and we just need to flatten that tree. We do this in DFS order for
  readability.
*)

let rec program fmt (_, stmts, _) =
  Format.set_margin 80;
  let prefix  = "" in
  let scope = get_modules_in_scope [] "" stmts in
  let modules = filter_modules prefix scope stmts in
  let not_modules = filter_not_modules stmts in
  fprintf fmt "@[<v>@,%a%a@]@."
    print_modules modules
    (list ~sep:"" (statement scope prefix)) not_modules

(*
  print_modules calls print_module in a DFS order. It can easily be
  converted to BFS order by changing find_child_moduels.
*)

and print_modules fmt = function
  | [] -> ()
  | (prefix, scope, x) :: xs ->
    fprintf fmt "%a@,%a"
      (print_module scope prefix) x
      print_modules (find_child_modules xs prefix scope x)

and print_module scope prefix fmt = Statement.(function

  (* First we compute all the possible instances of module
     references and then take an intersection with the list of modules
     in scope which are defined in the same file to get a subset of
     actual references to other modules.  *)

  | _, ModuleDeclaration { Module.id; body; } ->
    let new_prefix = get_name prefix id in
    let new_scope = get_modules_in_scope scope new_prefix body in
    let list_possible_modules = get_modules_used body in
    let list_modules_used =
      get_modules_to_import new_scope list_possible_modules in

    fprintf fmt "@[<v>declare module %s {@;<0 2>@[<v>%a%a@]@,}@]"
      new_prefix
      (list_ ~sep:"" import_module) list_modules_used
      (_list ~sep:"" (statement new_scope new_prefix))
      (filter_not_modules body)

  | _ -> todo fmt
)
and statement scope prefix fmt =
  Statement.(function
  | _, VariableDeclaration { VariableDeclaration.
      declarations; _
    } -> VariableDeclaration.(
      match declarations with
      | [(_, { Declarator.id; _ })] ->
          fprintf fmt "@[<hv>declare var %a;@]"
            pattern id
      | _ -> todo fmt
    )

  | _, InterfaceDeclaration { Interface.
      id; body; extends; typeParameters;
    } ->
      fprintf fmt "@[<v>declare class %a%a%a %a@]"
        id_ id
        (opt (non_empty "<@[<h>%a@]>" (list ~sep:"," type_param))) typeParameters
        extends_interface extends
        object_type (snd body)

  | _, ExportAssignment id ->
      fprintf fmt "@[<h>declare var exports: typeof %a;@]"
        id_ id

  | _, AmbientClassDeclaration { AmbientClass.
      id; body; typeParameters; extends; implements;
    } ->
      fprintf fmt "@[<v>declare class %a%a%a%a %a@]"
        id_ id
        (opt (non_empty "<@[<h>%a@]>" (list ~sep:"," type_param))) typeParameters
        extends_class extends
        implements_class implements
        object_type (snd body)

  | _, ExportModuleDeclaration { ExportModule.name; body; } ->
    let list_possible_modules = get_modules_used body in
    let list_modules_used =
      get_modules_to_import scope list_possible_modules in
    fprintf fmt "@[<v>declare module %s {@;<0 2>@[<v>%a%a@]@,}@]"
      name
      (list_ ~sep:"" import_module) list_modules_used
      (_list ~sep:"" (statement scope prefix))
      (filter_not_modules body)

  | _ ->
      todo fmt
)

and pattern fmt = Pattern.(function
  | _, Identifier id ->
      id_ fmt id
  | _ ->
      todo fmt
)

and id_ fmt = function
  | _, { Identifier.name; typeAnnotation; _ } ->
      fprintf fmt "%s%a"
        name
        (opt annot) typeAnnotation

and annot fmt =
  fprintf fmt ": %a" type_

and generic_type fmt = Type.(function
  | { Generic.id; typeArguments; } ->
      fprintf fmt "@[%a%a@]"
        id_path id
        (non_empty "<%a>" (list ~sep:"," type_)) typeArguments
)

(********************* TODO ************************)
and id_path fmt = function
  | _, { IdPath.ids; _ } ->
      fprintf fmt "@[<h>%a@]"
        (list ~sep:"." id_) ids

and type_ fmt = Type.(function
  | _, Any -> fprintf fmt "any"
  | _, Void -> fprintf fmt "void"
  | _, Number -> fprintf fmt "number"
  | _, String -> fprintf fmt "string"
  | _, Boolean -> fprintf fmt "boolean"
  | _, Function t -> function_type fmt t
  | _, Object t -> object_type fmt t
  | _, Array t -> array_type fmt t
  | _, Generic t -> generic_type fmt t
  | _ -> todo fmt
)

and type_param fmt = Type.(function
  | { Param.id; _ } ->
      id_ fmt id
)

(* A class can only extend one class unlike interfaces which can
   extend multiple interfaces. Thus, the same function does not work
   for classes.

   declare module M {
       export class A extends B { }
       export class D { }
   }

   In the above .d.ts program we see that class A have "extends"
   property where as class D does not. Thus "extends" is
   an optional property. This is handled in the extends_class_ function.

*)
and extends_class fmt = function
  | None -> ()
  | Some (_, t) ->
      fprintf fmt "@[ extends %a@]"
        generic_type t

(* This helper function is for handling extend statement in an
   interface declration. Since an interface can extend more than one
   interfaces, we have a list of interfaces which are extended by the
   current interface.
*)
and extends_interface fmt = function
  | [] -> ()
  | [_, t] ->
      fprintf fmt "@[ extends %a@]"
        generic_type t
  | _ -> todo fmt

(* Implements_class is a helper function to print "implements"
   property in a class. A class can have more than one or zero
   interface so we have a list of interfaces which are implemented by
   he current class.

   Eg. :

   declare module M {
       export class A extends B implements C { }
   }

*)
and implements_class fmt = function
  | [] -> ()
  | [_, t] ->
      fprintf fmt "@[ implements %a@]"
        generic_type t
  | _ -> todo fmt

and object_type fmt = Type.(function
  | { Object.properties; indexers; } ->
      fprintf fmt "{@;<0 2>@[<v>%a%a@]@,}"
        (list_ ~sep:";" property) properties
        (list ~sep:";" indexer_) indexers
)

and property fmt = Type.Object.(function
  | _, { Property.key; value; _ } ->
    (match key, value with
      | (Expression.Object.Property.Identifier id, (_,Type.Function value)) ->
          fprintf fmt "@[<hv>%a%a@]"
            id_ id
            method_type value
      | (Expression.Object.Property.Identifier id, _) ->
          fprintf fmt "@[<hv>%a: %a@]"
            id_ id
            type_ value
      | _ -> todo fmt
    )
)

and indexer_ fmt = Type.Object.(function
  | _, { Indexer.id; key; value; } ->
      fprintf fmt "@[<hv>[%a: %a]: %a@]"
        id_ id
        type_ key
        type_ value
)

and array_type fmt t =
  fprintf fmt "Array<%a>"
    type_ t

and function_type fmt = Type.(function
  | { Function.typeParameters; params; rest; returnType; } ->
      fprintf fmt "%a(@;<0 2>@[<hv>%a%a@]@,) => %a"
        (non_empty "<@[<h>%a@]>" (list ~sep:"," type_param)) typeParameters
        (list ~sep:", " param) params
        (opt (rest_ ~follows:(params <> []))) rest
        type_ returnType
)

and method_type fmt = Type.(function
  | { Function.typeParameters; params; rest; returnType; } ->
      fprintf fmt "%a(@;<0 2>@[<hv>%a%a@]@,): %a"
        (non_empty "<@[<h>%a@]>" (list ~sep:"," type_param)) typeParameters
        (list ~sep:", " param) params
        (opt (rest_ ~follows:(params <> []))) rest
        type_ returnType
)

and param fmt = Type.Function.(function
  | _, { Param.name; typeAnnotation; optional } ->
    if optional
    then fprintf fmt "%a?: %a"
      id_ name
      type_ typeAnnotation
    else fprintf fmt "%a: %a"
      id_ name
      type_ typeAnnotation
)

and rest_ ?(follows=false) fmt = Type.Function.(function
  | _, { Param.name; typeAnnotation; _ } ->
    let sep = if follows then ", " else "" in
    fprintf fmt "%s...%a: %a"
      sep
        id_ name
      type_ typeAnnotation
)

(* This prints the import module statement. Since currently, the flow
   parser does not parse import statements inside a module
   declaration, we use this hack of $Exports
*)
and import_module fmt = function
  | (x, y) -> fprintf fmt "declare var %s: $Exports<'%s'>;" x y
