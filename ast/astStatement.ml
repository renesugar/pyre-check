(** Copyright (c) 2016-present, Facebook, Inc.

    This source code is licensed under the MIT license found in the
    LICENSE file in the root directory of this source tree. *)

open Core

open Pyre

module Expression = AstExpression
module Parameter = AstParameter
module Identifier = AstIdentifier
module Location = AstLocation
module Node = AstNode

module Argument = Expression.Argument


module Record = struct
  module Define = struct
    type 'statement record = {
      name: Expression.Access.t;
      parameters: (Expression.t Parameter.t) list;
      body: 'statement list;
      decorators: Expression.t list;
      docstring: string option;
      return_annotation: Expression.t option;
      async: bool;
      generated: bool;
      parent: Expression.Access.t option; (* The class owning the method. *)
    }
    [@@deriving compare, eq, sexp, show, hash]
  end

  module Class = struct
    type 'statement record = {
      name: Expression.Access.t;
      bases: Argument.t list;
      body: 'statement list;
      decorators: Expression.t list;
      docstring: string option;
    }
    [@@deriving compare, eq, sexp, show, hash]
  end

  module For = struct
    type 'statement record = {
      target: Expression.t;
      iterator: Expression.t;
      body: 'statement list;
      orelse: 'statement list;
      async: bool;
    }
    [@@deriving compare, eq, sexp, show, hash]
  end

  module With = struct
    type 'statement record = {
      items: (Expression.t * Expression.t option) list;
      body: 'statement list;
      async: bool;
    }
    [@@deriving compare, eq, sexp, show, hash]
  end

  module Try = struct
    type 'statement handler = {
      kind: Expression.t option;
      name: Identifier.t option;
      handler_body: 'statement list;
    }
    [@@deriving compare, eq, sexp, show, hash]


    type 'statement record = {
      body: 'statement list;
      handlers: 'statement handler list;
      orelse: 'statement list;
      finally: 'statement list;
    }
    [@@deriving compare, eq, sexp, show, hash]
  end
end


(* Not sure why the OCaml compiler hates me... *)
module RecordWith = Record.With
module RecordFor = Record.For
module RecordTry = Record.Try


module While = struct
  type 'statement t = {
    test: Expression.t;
    body: 'statement list;
    orelse: 'statement list;
  }
  [@@deriving compare, eq, sexp, show, hash]
end


module If = struct
  type 'statement t = {
    test: Expression.t;
    body: 'statement list;
    orelse: 'statement list;
  }
  [@@deriving compare, eq, sexp, show, hash]
end


module Assert = struct
  type t = {
    test: Expression.t;
    message: Expression.t option;
  }
  [@@deriving compare, eq, sexp, show, hash]
end


module Import = struct
  type import = {
    name: Expression.Access.t;
    alias: Expression.Access.t option;
  }
  [@@deriving compare, eq, sexp, show, hash]


  type t = {
    from: Expression.Access.t option;
    imports: import list;
  }
  [@@deriving compare, eq, sexp, show, hash]
end


module Assign = struct
  type t = {
    target: Expression.t;
    annotation: Expression.t option;
    value: Expression.t option;
    parent: Expression.Access.t option;
  }
  [@@deriving compare, eq, sexp, show, hash]


  let is_static_attribute_initialization { parent; _ } =
    Option.is_some parent
end


module Stub = struct
  type 'statement t =
    | Assign of Assign.t
    | Class of 'statement Record.Class.record
    | Define of 'statement Record.Define.record
  [@@deriving compare, eq, sexp, show, hash]
end


type statement =
  | Assign of Assign.t
  | Assert of Assert.t
  | Break
  | Class of t Record.Class.record
  | Continue
  | Define of t Record.Define.record
  | Delete of Expression.t
  | Expression of Expression.t
  | For of t Record.For.record
  | Global of Identifier.t list
  | If of t If.t
  | Import of Import.t
  | Nonlocal of Identifier.t list
  | Pass
  | Raise of Expression.t option
  | Return of Expression.t option
  | Stub of t Stub.t
  | Try of t Record.Try.record
  | With of t Record.With.record
  | While of t While.t
  | Yield of Expression.t
  | YieldFrom of Expression.t


and t = statement Node.t
[@@deriving compare, eq, sexp, show, hash]


type statement_t = t
[@@deriving compare, eq, sexp, show, hash]


module Attribute = struct
  type attribute = {
    target: Expression.t;
    annotation: Expression.t option;
    defines: ((statement_t Record.Define.record) list) option;
    value: Expression.t option;
    async: bool;
    setter: bool;
    primitive: bool;
  }
  [@@deriving compare, eq, sexp, show, hash]

  type t = attribute Node.t
  [@@deriving compare, eq, sexp, show, hash]

  let create
      ~location
      ?(async = false)
      ?(setter = false)
      ?(primitive = false)
      ?value
      ?annotation
      ?defines
      ~target
      () =
    { target; annotation; defines; value; async; setter; primitive }
    |> Node.create ~location
end


module Define = struct
  include Record.Define


  type t = statement_t Record.Define.record
  [@@deriving compare, eq, sexp, show, hash]


  let create_toplevel statements =
    {
      name = Expression.Access.create "$toplevel";
      parameters = [];
      body = statements;
      decorators = [];
      docstring = None;
      return_annotation = None;
      async = false;
      generated = false;
      parent = None;
    }


  let is_method { name; parent; _ } =
    Option.is_some parent && List.length name = 1


  let has_decorator { decorators; _ } decorator =
    let open Expression in
    let rec is_decorator expected actual =
      match expected, actual with
      | (expected_decorator :: expected_decorators),
        { Node.location; value = Access ((Access.Identifier identifier) :: identifiers) }
        when Identifier.show identifier = expected_decorator ->
          if List.is_empty expected_decorators && List.is_empty identifiers then
            true
          else
            is_decorator expected_decorators { Node.location; value = Access identifiers }
      | _ ->
          false
    in
    List.exists ~f:(is_decorator (String.split ~on:'.' decorator)) decorators


  let is_coroutine define =
    has_decorator define "asyncio.coroutines.coroutine"


  let is_abstract_method define =
    has_decorator define "abstractmethod" ||
    has_decorator define "abc.abstractmethod" ||
    has_decorator define "abstractproperty" ||
    has_decorator define "abc.abstractproperty"


  let is_overloaded_method define =
    has_decorator define "overload" ||
    has_decorator define "typing.overload"


  let is_static_method define =
    has_decorator define "staticmethod"


  let is_class_method define =
    Set.exists ~f:(has_decorator define) Recognized.classmethod_decorators


  let is_constructor ?(in_test = false) { name; parent; _ } =
    let name = Expression.Access.show name in
    if Option.is_none parent then
      false
    else
      name = "__init__" ||
      (in_test &&
       List.mem ~equal:String.equal ["setUp"; "_setup"; "_async_setup"; "with_context"] name)


  let is_generated_constructor { generated; _ } = generated


  let is_property_setter ({ name; _ } as define) =
    has_decorator define ((Expression.Access.show name) ^ ".setter")


  let is_untyped { return_annotation; _ } =
    Option.is_none return_annotation


  let is_async { async; _ } =
    async


  let is_toplevel { name; _ } =
    Expression.Access.show name = "$toplevel"


  let create_generated_constructor { Record.Class.name; docstring; _ } =
    {
      name = Expression.Access.create "__init__";
      parameters = [Parameter.create ~name:(Identifier.create "self") ()];
      body = [Node.create_with_default_location Pass];
      decorators = [];
      return_annotation = None;
      async = false;
      generated = true;
      parent = Some name;
      docstring;
    }

  let contains_call { body; _ } name =
    let matches = function
      | {
        Node.value = Expression {
            Node.value = Expression.Access [
                Expression.Access.Identifier identifier;
                Expression.Access.Call _;
              ];
            _;
          };
        _;
      } when Identifier.show identifier = name ->
          true
      | _ ->
          false
    in
    List.exists ~f:matches body


  let dump define =
    contains_call define "pyre_dump"


  let dump_cfg define =
    contains_call define "pyre_dump_cfg"


  let self_identifier { parameters; _ } =
    match parameters with
    | { Node.value = { Parameter.name; _ }; _ } :: _ -> name
    | _ -> Identifier.create "self"


  let implicit_attributes
      ({ body; parameters; _ } as define)
      ~definition:{ Record.Class.body = definition_body; _ } =
    let open Expression in
    let parameter_annotations =
      let add_parameter map = function
        | { Node.value = { Parameter.name; annotation = Some annotation; _ }; _ } ->
            Map.set map ~key:(Access.create_from_identifiers [name]) ~data:annotation
        | _ ->
            map
      in
      List.fold ~init:Access.Map.empty ~f:add_parameter parameters
    in
    let attribute map { Node.location; value } =
      match value with
      | Assign { Assign.target; annotation; value; _ } ->
          let annotation =
            match annotation, value with
            | None, Some { Node.value = Access access; _ } ->
                Map.find parameter_annotations access
            | _ ->
                annotation
          in
          let attribute map target =
            match target with
            | ({
                Node.value = Access ((Access.Identifier self) :: ([_] as access));
                _;
              } as target) when Identifier.equal self (self_identifier define) ->
                let attribute =
                  let target = { target with Node.value = Access access } in
                  Attribute.create ~primitive:true ~location ~target ?annotation ?value ()
                in
                let update = function
                  | Some attributes -> Some (attribute :: attributes)
                  | None -> Some [attribute]
                in
                Map.change ~f:update map access
            | _ ->
                map
          in
          let targets =
            match target with
            | { Node.value = Access _; _ } as target ->
                [target]
            | { Node.value = Tuple targets; _ } ->
                targets
            | _ ->
                []
          in
          List.fold ~init:map ~f:attribute targets
      | _ ->
          map
    in
    let merge_attributes = function
      | [attribute] ->
          attribute
      | ({ Node.location; value = attribute } :: _) as attributes ->
          let annotation =
            let annotation = function
              | { Node.value = { Attribute.annotation = Some annotation; _ }; _ } -> Some annotation
              | _ -> None
            in
            match List.filter_map ~f:annotation attributes with
            | [] ->
                None
            | ({ Node.location; _ } as annotation) :: annotations ->
                if List.for_all ~f:(Expression.equal annotation) annotations then
                  Some annotation
                else
                  let argument =
                    {
                      Argument.name = None;
                      value = Node.create_with_default_location (Tuple (annotation :: annotations));
                    }
                  in
                  Some {
                    Node.location;
                    value = Access [
                        Access.Identifier (Identifier.create "typing");
                        Access.Identifier (Identifier.create "Union");
                        Access.Identifier (Identifier.create "__getitem__");
                        Access.Call (Node.create_with_default_location [argument]);
                      ];
                  }
          in
          { Node.location; value = { attribute with Attribute.annotation }}
      | [] ->
          failwith "Unpossible!"
    in
    let rec expand_statements body =
      (* Can't use `Visit` module due to circularity :( *)
      let expand_statement ({ Node.value; _ } as statement) =
        match value with
        | If { If.body; orelse; _ }
        | For { RecordFor.body; orelse; _ }
        | While { While.body; orelse; _ } ->
            (expand_statements body) @ (expand_statements orelse)
        | Try { RecordTry.body; orelse; finally; _ } ->
            (expand_statements body) @ (expand_statements orelse) @ (expand_statements finally)
        | With { RecordWith.body; _ } ->
            expand_statements body
        | Expression {
            Node.value =
              Expression.Access [
                Expression.Access.Identifier self;
                Expression.Access.Identifier name;
                Expression.Access.Call _;
              ];
            _;
          } when Identifier.equal self (self_identifier define) ->
            (* Look for method in class definition. *)
            let inline = function
              | { Node.value = Define { name = callee; body; _ }; _ }
                when Expression.Access.show callee = Identifier.show name ->
                  Some body
              | _ ->
                  None
            in
            List.find_map ~f:inline definition_body
            |> Option.value ~default:[statement]
        | _ ->
            [statement]
      in
      List.concat_map ~f:expand_statement body
    in
    expand_statements body
    |> List.fold ~init:Expression.Access.Map.empty ~f:attribute
    |> Map.map ~f:merge_attributes


  let property_attribute ~location ({ name; return_annotation; parameters; _ } as define) =
    let attribute annotation =
      Attribute.create
        ~location
        ~target:(Node.create ~location (Expression.Access name))
        ?annotation
        ~async:(is_async define)
        ()
    in
    match String.Set.find ~f:(has_decorator define) Recognized.property_decorators with
    | Some "util.classproperty"
    | Some "util.etc.cached_classproperty"
    | Some "util.etc.class_property" ->
        let return_annotation =
          let open Expression in
          match return_annotation with
          | Some ({ Node.location; value = Access _ } as access) ->
              let argument =
                {
                  Argument.name = None;
                  value = access;
                }
              in
              Some {
                Node.location;
                value = Access [
                    Access.Identifier (Identifier.create "typing");
                    Access.Identifier (Identifier.create "ClassVar");
                    Access.Identifier (Identifier.create "__getitem__");
                    Access.Call (Node.create_with_default_location [argument]);
                  ];
              }
          | _ ->
              None
        in
        Some (attribute return_annotation)
    | Some _ ->
        Some (attribute return_annotation)
    | None ->
        begin
          match is_property_setter define, parameters with
          | true, _ :: { Node.value = { Parameter.annotation; _ }; _ } :: _ ->
              (Some
                 (Attribute.create
                    ~location
                    ~target:(Node.create ~location (Expression.Access name))
                    ?annotation
                    ~setter:true
                    ~async:(is_async define)
                    ()))
          | _ ->
              None
        end
end


let assume ({ Node.location; _ } as test) =
  {
    Node.location;
    value = Assert { Assert.test; message = None };
  }


(* Naive assumptions *)
let terminates body =
  let find_terminator = function
    | { Node.value = Return _; _ }
    | { Node.value = Raise _; _ }
    | { Node.value = Continue; _ } -> true
    | _ -> false
  in
  Option.is_some (List.find ~f:find_terminator body)


module Class = struct
  include Record.Class


  type t = statement_t Record.Class.record
  [@@deriving compare, eq, sexp, show, hash]


  let constructors ?(in_test = false) { Record.Class.body; _ } =
    let constructor = function
      | { Node.value = Define define; _ } when Define.is_constructor ~in_test define ->
          Some define
      | _ ->
          None
    in
    List.filter_map ~f:constructor body


  let attributes
      ?(include_generated_attributes = true)
      ?(in_test = false)
      ({ Record.Class.body; _ } as definition) =
    let explicitly_assigned_attributes =
      let assigned_attributes map { Node.location; value } =
        let open Expression in
        match value with
        | Assign {
            Assign.target = { Node.value = Access ([_] as access); _ } as target;
            annotation;
            value;
            _;
          }
        | Stub
            (Stub.Assign
               {
                 Assign.target = { Node.value = Access ([_] as access); _ } as target;
                 annotation;
                 value;
                 _;
               }) ->
            let attribute =
              Attribute.create
                ~primitive:true
                ~location
                ~target
                ?annotation
                ?value
                ()
            in
            Map.set ~key:access ~data:attribute map
        (* Handle multiple assignments on same line *)
        | Assign {
            Assign.target = { Node.value = Tuple targets; _ };
            value = Some { Node.value = Tuple values; _ };
            _;
          }
        | Stub
            (Stub.Assign
               {
                 Assign.target = { Node.value = Tuple targets; _ };
                 value = Some { Node.value = Tuple values; _ };
                 _;
               }) ->
            let add_attribute map access_node value =
              match Node.value access_node with
              | Access ([_] as access) ->
                  let attribute =
                    Attribute.create
                      ~primitive:true
                      ~location
                      ~target:access_node
                      ~value
                      ()
                  in
                  Map.set ~key:access ~data:attribute map
              | _ ->
                  map
            in
            if List.length targets = List.length values then
              List.fold2_exn ~init:map ~f:add_attribute targets values
            else
              map
        | Assign {
            Assign.target = { Node.value = Tuple targets; _ };
            value = Some ({ Node.value = Access values; location } as value);
            _;
          }
        | Stub
            (Stub.Assign
               {
                 Assign.target = { Node.value = Tuple targets; _ };
                 value = Some ({ Node.value = Access values; location } as value);
                 _;
               }) ->
            let add_attribute index map access_node =
              match Node.value access_node with
              | Access ([_] as access) ->
                  let attribute =
                    let value =
                      let get_item =
                        let index = Node.create ~location (Integer index) in
                        [
                          Access.Identifier (Identifier.create "__getitem__");
                          Access.Call
                            (Node.create ~location [{ Argument.name = None; value = index }]);
                        ]
                      in
                      { value with Node.value = Access (values @ get_item) }
                    in
                    Attribute.create ~primitive:true ~location ~target:access_node ~value ()
                  in
                  Map.set ~key:access ~data:attribute map
              | _ ->
                  map
            in
            List.foldi ~init:map ~f:add_attribute targets
        | _ ->
            map
      in
      List.fold ~init:Expression.Access.Map.empty ~f:assigned_attributes body
    in

    if not include_generated_attributes then
      explicitly_assigned_attributes
    else
      let merge ~key:_ = function
        | `Both (_, right) ->
            Some right
        | `Left value
        | `Right value ->
            Some value
      in
      let implicitly_assigned_attributes =
        constructors ~in_test definition
        |> List.map ~f:(Define.implicit_attributes ~definition)
        |> List.fold ~init:Expression.Access.Map.empty ~f:(Map.merge ~f:merge)
      in
      let property_attributes =
        let property_attributes map = function
          | { Node.location; value = Stub (Stub.Define define) }
          | { Node.location; value = Define define } ->
              begin
                match Define.property_attribute ~location define with
                | Some ({
                    Node.value =
                      ({
                        Attribute.target =
                          { Node.value = Expression.Access ([_] as access); _ };
                        setter = new_setter;
                        annotation = new_annotation;
                        _;
                      } as attribute);
                    _;
                  } as attribute_node) ->
                    let merged_attribute =
                      match Map.find map access, new_setter with
                      | Some { Node.value = { Attribute.setter = true; annotation; _ }; _ },
                        false ->
                          {
                            attribute with
                            Attribute.annotation;
                            value = new_annotation;
                            setter = true
                          }
                          |> (fun edited -> { attribute_node with Node.value = edited })
                      | Some { Node.value = { Attribute.setter = false; annotation; _ }; _ },
                        true ->
                          {
                            attribute with
                            Attribute.annotation = new_annotation;
                            value = annotation;
                            setter = true
                          }
                          |> (fun edited -> { attribute_node with Node.value = edited })
                      | _ ->
                          attribute_node
                    in
                    Map.set ~key:access ~data:merged_attribute map
                | _ ->
                    map
              end
          | _ ->
              map
        in
        List.fold ~init:Expression.Access.Map.empty ~f:property_attributes body
      in
      let callable_attributes =
        let callable_attributes map { Node.location; value } =
          match value with
          | Stub (Stub.Define ({ Define.name; _ } as define))
          | Define ({ Define.name; _ } as define) ->
              let attribute =
                match Map.find map name with
                | Some { Node.value = { Attribute.defines = Some defines; _ }; _ } ->
                    Attribute.create
                      ~location
                      ~target:(Node.create ~location (Expression.Access name))
                      ~defines:({ define with Define.body = [] } :: defines)
                      ()
                | _ ->
                    Attribute.create
                      ~location
                      ~target:(Node.create ~location (Expression.Access name))
                      ~defines:[{ define with Define.body = [] }]
                      ()
              in
              Map.set map ~key:name ~data:attribute
          | _ ->
              map
        in
        List.fold ~init:Expression.Access.Map.empty ~f:callable_attributes body
      in
      let class_attributes =
        let callable_attributes map { Node.location; value } =
          match value with
          | Stub (Stub.Class { Record.Class.name; _ })
          | Class { Record.Class.name; _ } when not (List.is_empty name) ->
              let open Expression in
              let annotation =
                let meta_annotation =
                  let argument =
                    {
                      Argument.name = None;
                      value = Node.create_with_default_location (Access name);
                    }
                  in
                  Node.create
                    ~location
                    (Access [
                        Access.Identifier (Identifier.create "typing");
                        Access.Identifier (Identifier.create "Type");
                        Access.Identifier (Identifier.create "__getitem__");
                        Access.Call (Node.create_with_default_location [argument]);
                      ])
                in
                let argument = { Argument.name = None; value = meta_annotation } in
                Node.create
                  ~location
                  (Access [
                      Access.Identifier (Identifier.create "typing");
                      Access.Identifier (Identifier.create "ClassVar");
                      Access.Identifier (Identifier.create "__getitem__");
                      Access.Call (Node.create_with_default_location [argument]);
                    ])
              in
              Map.set
                ~key:name
                ~data:(
                  Attribute.create
                    ~location
                    ~target:(Node.create ~location (Expression.Access [List.last_exn name]))
                    ~annotation
                    ())
                map
          | _ ->
              map
        in
        List.fold ~init:Expression.Access.Map.empty ~f:callable_attributes body
      in
      (* Merge with decreasing priority. Explicit attributes override all. *)
      explicitly_assigned_attributes
      |> Map.merge ~f:merge implicitly_assigned_attributes
      |> Map.merge ~f:merge property_attributes
      |> Map.merge ~f:merge callable_attributes
      |> Map.merge ~f:merge class_attributes


  let update
      { Record.Class.body = stub; _ }
      ~definition:({ Record.Class.body; _ } as definition) =
    let updated, undefined =
      let update (updated, undefined) statement =
        match statement with
        | { Node.location; value = Assign ({ Assign.target; _ } as assign)} ->
            begin
              let is_stub = function
                | { Node.value = Stub (Stub.Assign { Assign.target = stub_target; _ }); _ }
                | { Node.value = Assign { Assign.target = stub_target; _; }; _; }
                  when Expression.equal target stub_target ->
                    true
                | _ ->
                    false
              in
              match List.find ~f:is_stub stub with
              | Some { Node.value = Stub (Stub.Assign { Assign.annotation; _ }); _ } ->
                  let updated_assign =
                    {
                      Node.location;
                      value = Assign { assign with Assign.annotation }
                    }
                  in
                  updated_assign :: updated,
                  (List.filter ~f:(fun statement -> not (is_stub statement)) undefined)
              | _ ->
                  statement :: updated, undefined
            end
        | { Node.location; value = Define ({ Record.Define.name; parameters; _ } as define)} ->
            begin
              let is_stub = function
                | {
                  Node.value = Stub (Stub.Define {
                      Record.Define.name = stub_name;
                      parameters = stub_parameters;
                      _;
                    });
                  _;
                }
                | {
                  Node.value = Define {
                      Record.Define.name = stub_name;
                      parameters = stub_parameters;
                      _;
                    };
                  _;
                } when Expression.Access.equal name stub_name &&
                       List.length parameters = List.length stub_parameters ->
                    true
                | _ ->
                    false
              in
              match List.find ~f:is_stub stub with
              | Some {
                  Node.value = Stub (Stub.Define { Define.parameters; return_annotation; _ });
                  _;
                } ->
                  let updated_define =
                    {
                      Node.location;
                      value = Define { define with Define.parameters; return_annotation }
                    }
                  in
                  updated_define :: updated,
                  (List.filter ~f:(fun statement -> not (is_stub statement)) undefined)
              | _ ->
                  statement :: updated, undefined
            end
        | _ ->
            statement :: updated, undefined
      in
      List.fold ~init:([], stub) ~f:update body
    in
    { definition with Record.Class.body = undefined @ updated }
end


module For = struct
  include Record.For


  type t = statement_t Record.For.record
  [@@deriving compare, eq, sexp, show, hash]


  let preamble
      {
        target = { Node.location; _ } as target;
        iterator = { Node.value; _ };
        async;
        _;
      } =
    let open Expression in
    let value =
      let next =
        if async then
          (Access.call ~name:"__aiter__" ~location ()) @
          (Access.call ~name: "__anext__" ~location ())
        else
          (Access.call ~name:"__iter__" ~location ()) @
          (Access.call ~name: "__next__" ~location ())
      in
      begin
        match value with
        | Access access ->
            access @ next
        | expression ->
            [Access.Expression (Node.create_with_default_location expression)] @ next
      end
    in
    {
      Node.location;
      value = Assign {
          Assign.target;
          annotation = None;
          value = Some {
              Node.location;
              value = Access value;
            };
          parent = None;
        }
    }
end


module With = struct
  include Record.With


  type t = statement_t Record.With.record
  [@@deriving compare, eq, sexp, show, hash]


  let preamble { items; async; _ } =
    let preamble ({ Node.location; _ } as expression, target) =
      (target
       >>| fun target ->
       let open Expression in
       let enter_call =
         let base_call =
           let enter_call_name =
             if async then
               "__aenter__"
             else
               "__enter__"
           in
           Access
             ((Expression.access expression) @ (Access.call ~name:enter_call_name ~location ()))
           |> Node.create ~location
         in
         if async then
           Node.create ~location (Await base_call)
         else
           base_call
       in
       let assign =
         {
           Assign.target;
           annotation = None;
           value = Some enter_call;
           parent = None;
         }
       in
       Node.create ~location (Assign assign))
      |> Option.value ~default:(Node.create ~location (Expression expression))
    in
    List.map ~f:preamble items
end


module Try = struct
  include Record.Try


  type t = statement_t Record.Try.record
  [@@deriving compare, eq, sexp, show, hash]


  let preamble { kind; name; _ } =
    let open Expression in
    let name =
      name
      >>| Identifier.show
      >>| Access.create
    in
    let assume ~location ~target ~annotation =
      {
        Node.location;
        value = Assign {
            Assign.target;
            annotation = Some annotation;
            value = None;
            parent = None;
          }
      }
    in
    match kind, name with
    | Some ({ Node.location; value = Access _; _ } as annotation), Some name ->
        [assume ~location ~target:{ Node.location; value = Access name } ~annotation]
    | Some { Node.location; value = Tuple values; _ }, Some name ->
        let annotation =
          let get_item =
            let tuple =
              Tuple values
              |> Node.create ~location
            in
            Access.call
              ~arguments:[{ Argument.name = None; value = tuple }]
              ~location
              ~name:"__getitem__"
              ()
          in
          {
            Node.location;
            value = Access ((Access.create "typing.Union") @ get_item);
          }
        in
        [assume ~location ~target:{ Node.location; value = Access name } ~annotation]
    | Some ({ Node.location; _ } as expression), _ ->
        (* Insert raw `kind` so that we type check the expression. *)
        [Node.create ~location (Expression expression)]
    | _ ->
        []
end


let extract_docstring statements =
  (* See PEP 257 for Docstring formatting. The main idea is that we want to get the shortest
   * indentation from line 2 onwards as the indentation of the docstring. *)
  let unindent docstring =
    let indentation line =
      let line_without_indentation = String.lstrip line in
      (String.length line) - (String.length line_without_indentation) in
    match String.split ~on:'\n' docstring with
    | [] -> docstring
    | first :: rest ->
        let indentations = List.map ~f:indentation rest in
        let difference = List.fold ~init:Int.max_value ~f:Int.min indentations in
        let rest = List.map ~f:(fun s -> String.drop_prefix s difference) rest in
        String.concat ~sep:"\n" (first::rest)
  in
  match statements with
  | { Node.value = Expression { Node.value = Expression.String s; _ }; _ } :: _ -> Some (unindent s)
  | _ -> None


module PrettyPrinter = struct
  let pp_decorators formatter =
    function
    | [] -> ()
    | decorators ->
        Format.fprintf
          formatter
          "@[<v>@@(%a)@;@]"
          Expression.pp_expression_list decorators


  let pp_access_list_option formatter =
    function
    | None -> ()
    | Some access_list ->
        Format.fprintf
          formatter
          "@[%a.@]"
          Expression.pp_expression_access_list access_list


  let pp_access_list formatter =
    function
    | [] -> ()
    | access_list ->
        Format.fprintf
          formatter
          "@[%a@]"
          Expression.pp_expression_access_list access_list


  let pp_list formatter pp sep list =
    let rec pp' formatter =
      function
      | [] -> ()
      | x :: [] -> Format.fprintf formatter "%a" pp x
      | x :: xs -> Format.fprintf formatter ("%a"^^sep^^"%a") pp x pp' xs
    in
    pp' formatter list


  let pp_option formatter option pp =
    Option.value_map option ~default:() ~f:(Format.fprintf formatter "%a" pp)


  let pp_option_with_prefix formatter (prefix,option) pp =
    Option.value_map
      option
      ~default:()
      ~f:(Format.fprintf formatter (prefix^^"%a") pp)


  let pp_expression_option formatter (prefix,option) =
    pp_option_with_prefix formatter (prefix,option) Expression.pp


  let pp_async formatter =
    function
    | true -> Format.fprintf formatter "async@;"
    | false -> ()


  let rec pp_statement_t formatter { Node.value = statement ; _ } =
    Format.fprintf formatter "%a" pp_statement statement


  and pp_statement_list formatter =
    function
    | [] -> ()
    | statement :: [] -> Format.fprintf formatter "%a" pp_statement_t statement
    | statement :: statement_list ->
        Format.fprintf
          formatter "%a@;%a"
          pp_statement_t statement
          pp_statement_list statement_list


  and pp_assign formatter { Assign.target; annotation; value; parent } =
    Format.fprintf
      formatter
      "%a%a = %a%a"
      pp_access_list_option parent
      Expression.pp target
      pp_expression_option ("", value)
      pp_expression_option (" # ", annotation)


  and pp_class formatter { Record.Class.name; bases; body; decorators; _ } =
    Format.fprintf
      formatter
      "%a@[<v 2>class %a(%a):@;@[<v>%a@]@;@]"
      pp_decorators decorators
      pp_access_list name
      Expression.pp_expression_argument_list bases
      pp_statement_list body


  and pp_define
      formatter
      { Define.name; parameters; body; decorators; return_annotation; async; parent; _ } =
    let return_annotation =
      match return_annotation with
      | Some annotation -> Format.asprintf " -> %a" Expression.pp annotation
      | _ -> ""
    in
    Format.fprintf
      formatter
      "%a@[<v 2>%adef %a%a(%a)%s:@;%a@]@."
      pp_decorators decorators
      pp_async async
      pp_access_list_option parent
      pp_access_list name
      Expression.pp_expression_parameter_list parameters
      return_annotation
      pp_statement_list body


  and pp_statement formatter statement =
    match statement with
    | Assign assign ->
        Format.fprintf
          formatter
          "%a"
          pp_assign assign

    | Assert { Assert.test; Assert.message } ->
        Format.fprintf
          formatter
          "assert %a, %a"
          Expression.pp test
          pp_expression_option ("", message)

    | Break ->
        Format.fprintf formatter "break"

    | Class definition ->
        Format.fprintf formatter "%a" pp_class definition

    | Continue ->
        Format.fprintf formatter "continue"

    | Define define ->
        Format.fprintf formatter "%a" pp_define define

    | Delete expression ->
        Format.fprintf formatter "del %a" Expression.pp expression

    | Expression expression ->
        Expression.pp formatter expression

    | For { For.target; iterator; body; orelse; async } ->
        Format.fprintf
          formatter
          "@[<v 2>%afor %a in %a:@;%a@]%a"
          pp_async async
          Expression.pp target
          Expression.pp iterator
          pp_statement_list body
          pp_statement_list orelse

    | Global global_list ->
        pp_list formatter Identifier.pp "," global_list

    | If { If.test; body; orelse } ->
        Format.fprintf
          formatter
          "@[<v>@[<v 2>if %a:@;%a@]@;@[<v 2>else:@;%a@]@]"
          Expression.pp test
          pp_statement_list body
          pp_statement_list orelse

    | Import { Import.from; imports } ->
        let pp_from formatter access_list =
          pp_option_with_prefix formatter ("from ", access_list) pp_access_list
        in
        let pp_import formatter { Import.name; alias } =
          let pp_alias_option formatter access_list =
            pp_option_with_prefix formatter ("as ", access_list) pp_access_list
          in
          Format.fprintf
            formatter
            "%a%a"
            pp_access_list name
            pp_alias_option alias
        in
        let pp_imports formatter import_list =
          pp_list formatter pp_import ", " import_list
        in
        Format.fprintf
          formatter
          "@[<v>%a import %a@]"
          pp_from from
          pp_imports imports

    | Nonlocal nonlocal_list ->
        pp_list formatter Identifier.pp "," nonlocal_list

    | Pass ->
        Format.fprintf formatter "%s" "pass"

    | Raise expression ->
        Format.fprintf
          formatter
          "raise %a"
          pp_expression_option ("", expression)

    | Return expression ->
        Format.fprintf
          formatter
          "return %a"
          pp_expression_option ("", expression)

    | Stub (Stub.Assign assign) ->
        Format.fprintf
          formatter
          "%a"
          pp_assign assign

    | Stub (Stub.Class definition) ->
        Format.fprintf formatter "%a" pp_class definition

    | Stub (Stub.Define define) ->
        Format.fprintf formatter "%a" pp_define define

    | Try { Record.Try.body; handlers; orelse; finally } ->
        let pp_try_block formatter body =
          Format.fprintf
            formatter
            "@[<v 2>try:@;%a@]"
            pp_statement_list body
        in
        let pp_except_block formatter handlers =
          let pp_as formatter name =
            pp_option_with_prefix formatter (" as ", name) Identifier.pp
          in
          let pp_handler formatter { Record.Try.kind; name; handler_body } =
            Format.fprintf
              formatter
              "@[<v 2>except%a%a:@;%a@]"
              pp_expression_option (" ", kind)
              pp_as name
              pp_statement_list handler_body
          in
          let pp_handler_list formatter handler_list =
            pp_list formatter pp_handler "@;" handler_list
          in
          Format.fprintf
            formatter
            "%a"
            pp_handler_list handlers
        in
        let pp_else_block formatter =
          function
          | [] -> ()
          | orelse ->
              Format.fprintf
                formatter
                "@[<v 2>else:@;%a@]"
                pp_statement_list orelse
        in
        let pp_finally_block formatter =
          function
          | [] -> ()
          | finally ->
              Format.fprintf
                formatter
                "@[<v 2>finally:@;@[<v>%a@]@]"
                pp_statement_list finally
        in
        Format.fprintf
          formatter
          "@[<v>%a@;%a@;%a@;%a@]"
          pp_try_block body
          pp_except_block handlers
          pp_else_block orelse
          pp_finally_block finally

    | With { Record.With.items; body; async } ->
        let pp_item formatter (expression, expression_option) =
          Format.fprintf
            formatter
            "%a%a"
            Expression.pp expression
            pp_expression_option (" as ", expression_option)
        in
        let rec pp_item_list formatter =
          function
          | [] -> ()
          | item :: [] -> Format.fprintf formatter "%a" pp_item item
          | item :: item_list ->
              Format.fprintf formatter "%a,%a" pp_item item pp_item_list item_list
        in
        Format.fprintf
          formatter
          "@[<v 2>%a with %a:@;%a@]"
          pp_async async
          pp_item_list items
          pp_statement_list body

    | While { While.test; body; orelse } ->
        Format.fprintf
          formatter
          "@[<v 2>while %a:@;%a@]@[<v>%a@]"
          Expression.pp test
          pp_statement_list body
          pp_statement_list orelse

    | Yield expression -> Format.fprintf formatter "yield %a" Expression.pp expression
    | YieldFrom expression -> Format.fprintf formatter "yield from %a" Expression.pp expression


  let pp = pp_statement_t
end


let pp formatter statement =
  Format.fprintf
    formatter
    "%a"
    PrettyPrinter.pp statement


let show statement =
  Format.asprintf "%a" pp statement
