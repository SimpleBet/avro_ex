defmodule AvroEx.Schema.ParserTest do
  use ExUnit.Case, async: true

  alias AvroEx.{Schema}
  alias AvroEx.Schema.{Array, Context, Fixed, Parser, Primitive, Record, Reference, Union}
  alias AvroEx.Schema.Enum, as: AvroEnum
  alias AvroEx.Schema.Map, as: AvroMap

  describe "primitives" do
    test "it can parse primitives" do
      for p <- Parser.primitives() do
        p_string = to_string(p)
        assert %Schema{schema: schema, context: context} = Parser.parse!(p_string)

        assert %Primitive{type: ^p} = schema
        assert context == %Context{names: %{}}
      end
    end

    test "it can parse complex primitives" do
      for p <- Parser.primitives() do
        p_string = to_string(p)
        assert %Schema{schema: schema, context: context} = Parser.parse!(%{"type" => p_string})

        assert %Primitive{type: ^p} = schema
        assert context == %Context{names: %{}}
      end
    end

    test "it can parse complex primitives with additional fields" do
      for p <- Parser.primitives() do
        p_string = to_string(p)

        assert %Schema{schema: schema, context: context} =
                 Parser.parse!(%{
                   "type" => p_string,
                   "a" => 1,
                   "logicalType" => "timestamp-millis",
                   "name" => "complex"
                 })

        assert %Primitive{
                 type: ^p,
                 metadata: %{"a" => 1, "logicalType" => "timestamp-millis", "name" => "complex"}
               } = schema

        assert context == %Context{names: %{}}
      end
    end

    test "invalid primitives raise a DecodeError" do
      assert_raise AvroEx.Schema.DecodeError,
                   "Invalid schema format \"nope\"",
                   fn ->
                     Parser.parse!("nope")
                   end

      message = "Invalid schema format %{\"type\" => \"nada\"}"

      assert_raise AvroEx.Schema.DecodeError, message, fn ->
        Parser.parse!(%{"type" => "nada"})
      end
    end
  end

  describe "records" do
    test "can decode simple records" do
      assert %Schema{schema: schema, context: context} =
               Parser.parse!(%{
                 "type" => "record",
                 "name" => "kyc",
                 "aliases" => ["first_last"],
                 "namespace" => "beam.community",
                 "fields" => [
                   %{"name" => "first", "type" => "string", "default" => "bob", "extra" => "val"},
                   %{"name" => "last", "type" => "string"}
                 ]
               })

      assert schema == %Record{
               name: "kyc",
               namespace: "beam.community",
               aliases: ["first_last"],
               fields: [
                 %Record.Field{
                   name: "first",
                   type: %Primitive{type: :string},
                   default: "bob",
                   metadata: %{"extra" => "val"}
                 },
                 %Record.Field{name: "last", type: %Primitive{type: :string}}
               ]
             }

      assert context == %Context{
               names: %{
                 "beam.community.first_last" => schema,
                 "beam.community.kyc" => schema
               }
             }
    end

    test "records can have fields that are logicalTypes" do
      assert %Schema{schema: schema, context: context} =
               Parser.parse!(%{
                 "type" => "record",
                 "name" => "analytics",
                 "fields" => [
                   %{
                     "name" => "timestamp",
                     "type" => %{"type" => "string", "logicalType" => "timestamp-millis"}
                   }
                 ]
               })

      assert schema == %Record{
               name: "analytics",
               fields: [
                 %Record.Field{
                   name: "timestamp",
                   type: %Primitive{type: :string, metadata: %{"logicalType" => "timestamp-millis"}}
                 }
               ]
             }

      assert context == %Context{names: %{"analytics" => schema}}
    end

    test "fields defaults must be valid" do
      message = "Invalid default in Field<name=key> Schema Mismatch: Expected value of long, got \"wrong\""

      assert_raise AvroEx.Schema.DecodeError, message, fn ->
        Parser.parse!(%{
          "type" => "record",
          "name" => "bad_default",
          "fields" => [
            %{"name" => "key", "type" => "long", "default" => "wrong"}
          ]
        })
      end
    end

    test "creating a record without a name will raise" do
      message =
        "Schema missing required key `name` for AvroEx.Schema.Record in %{\"fields\" => [%{\"name\" => \"key\", \"type\" => \"long\"}], \"type\" => \"record\"}"

      assert_raise AvroEx.Schema.DecodeError, message, fn ->
        Parser.parse!(%{
          "type" => "record",
          "fields" => [
            %{"name" => "key", "type" => "long"}
          ]
        })
      end
    end

    test "names must be valid" do
      message =
        "Invalid name `123` for `name` in %{\"fields\" => [%{\"name\" => \"key\", \"type\" => \"long\"}], \"name\" => \"123\", \"type\" => \"record\"}"

      assert_raise AvroEx.Schema.DecodeError, message, fn ->
        Parser.parse!(%{
          "type" => "record",
          "name" => "123",
          "fields" => [
            %{"name" => "key", "type" => "long"}
          ]
        })
      end
    end

    test "field names must be unique" do
      message = "Duplicate name `key` found in Record<name=duplicate_names>"

      assert_raise AvroEx.Schema.DecodeError, message, fn ->
        Parser.parse!(%{
          "type" => "record",
          "name" => "duplicate_names",
          "fields" => [
            %{"name" => "key", "type" => "long"},
            %{"name" => "key", "type" => "long"}
          ]
        })
      end
    end

    test "namespace must be valid" do
      message =
        "Invalid name `1invalid` for `namespace` in %{\"fields\" => [%{\"name\" => \"key\", \"type\" => \"long\"}], \"name\" => \"valid\", \"namespace\" => \"1invalid\", \"type\" => \"record\"}"

      assert_raise AvroEx.Schema.DecodeError, message, fn ->
        Parser.parse!(%{
          "type" => "record",
          "name" => "valid",
          "namespace" => "1invalid",
          "fields" => [
            %{"name" => "key", "type" => "long"}
          ]
        })
      end
    end
  end

  describe "unions" do
    test "it can decode simple unions" do
      assert %Schema{schema: schema, context: context} = Parser.parse!(["null", "string"])

      assert schema == %Union{
               possibilities: [
                 %Primitive{type: :null},
                 %Primitive{type: :string}
               ]
             }

      assert context == %Context{}
    end

    test "cannot have duplicated unnamed types" do
      message = "Union contains duplicated string in [\"string\", \"int\", \"string\"]"

      assert_raise AvroEx.Schema.DecodeError, message, fn ->
        Parser.parse!(["string", "int", "string"])
      end
    end

    test "can contain duplicated types if they are named" do
      assert %Schema{schema: schema, context: context} =
               Parser.parse!([
                 %{"type" => "enum", "name" => "directions", "symbols" => ["east", "north", "south", "west"]},
                 %{"type" => "enum", "name" => "primary_colors", "symbols" => ["blue", "red", "yellow"]}
               ])

      assert schema == %Union{
               possibilities: [
                 %AvroEnum{name: "directions", symbols: ["east", "north", "south", "west"]},
                 %AvroEnum{name: "primary_colors", symbols: ["blue", "red", "yellow"]}
               ]
             }

      assert context == %Context{
               names: %{
                 "directions" => %AvroEx.Schema.Enum{
                   name: "directions",
                   symbols: ["east", "north", "south", "west"]
                 },
                 "primary_colors" => %AvroEx.Schema.Enum{
                   name: "primary_colors",
                   symbols: ["blue", "red", "yellow"]
                 }
               }
             }
    end

    test "it can have children that are arrays" do
      assert %Schema{schema: schema, context: context} =
               Parser.parse!([
                 "null",
                 %{"type" => "array", "items" => "int"}
               ])

      assert schema == %Union{
               possibilities: [
                 %Primitive{type: :null},
                 %Array{items: %Primitive{type: :int}}
               ]
             }

      assert context == %Context{}
    end

    test "it cannot have multiple array children" do
      message =
        "Union contains duplicated Array<items=string> in [%{\"items\" => \"int\", \"type\" => \"array\"}, %{\"items\" => \"string\", \"type\" => \"array\"}]"

      assert_raise AvroEx.Schema.DecodeError, message, fn ->
        Parser.parse!([
          %{"type" => "array", "items" => "int"},
          %{"type" => "array", "items" => "string"}
        ])
      end
    end

    test "cannot have duplicated named types" do
      message =
        "Union contains duplicated Enum<name=directions> in [%{\"name\" => \"directions\", \"symbols\" => [\"east\", \"north\", \"south\", \"west\"], \"type\" => \"enum\"}, %{\"name\" => \"directions\", \"symbols\" => [\"blue\", \"red\", \"yellow\"], \"type\" => \"enum\"}]"

      assert_raise AvroEx.Schema.DecodeError, message, fn ->
        Parser.parse!([
          %{"type" => "enum", "name" => "directions", "symbols" => ["east", "north", "south", "west"]},
          %{"type" => "enum", "name" => "directions", "symbols" => ["blue", "red", "yellow"]}
        ])
      end
    end

    test "cannot be named at the top-level" do
      message = "Invalid schema format %{\"name\" => \"maybe_null\", \"type\" => [\"null\", \"string\"]}"

      assert_raise AvroEx.Schema.DecodeError, message, fn ->
        Parser.parse!(%{"name" => "maybe_null", "type" => ["null", "string"]})
      end
    end

    test "cannot have unions as direct children" do
      message =
        "Union contains nested union Union<possibilities=null|string> as immediate child in [\"string\", [\"null\", \"string\"]]"

      assert_raise AvroEx.Schema.DecodeError, message, fn ->
        Parser.parse!(["string", ["null", "string"]])
      end
    end
  end

  describe "enums" do
    test "can parse a basic enum" do
      assert %Schema{schema: schema, context: context} =
               Parser.parse!(%{
                 "type" => "enum",
                 "name" => "directions",
                 "namespace" => "beam.community",
                 "extra" => "val",
                 "symbols" => ["east", "north", "south", "west"]
               })

      assert schema == %AvroEnum{
               name: "directions",
               namespace: "beam.community",
               symbols: ["east", "north", "south", "west"],
               metadata: %{"extra" => "val"}
             }

      assert context == %Context{names: %{"beam.community.directions" => schema}}
    end

    test "cannot have duplicate symbols" do
      message =
        "Enum contains duplicated symbol `yes` in %{\"name\" => \"duplicate\", \"symbols\" => [\"yes\", \"no\", \"yes\"], \"type\" => \"enum\"}"

      assert_raise AvroEx.Schema.DecodeError, message, fn ->
        Parser.parse!(%{
          "type" => "enum",
          "name" => "duplicate",
          "symbols" => ["yes", "no", "yes"]
        })
      end
    end

    test "must have a valid name" do
      message =
        "Invalid name `bang!` for `name` in %{\"name\" => \"bang!\", \"symbols\" => [\"one\"], \"type\" => \"enum\"}"

      assert_raise AvroEx.Schema.DecodeError, message, fn ->
        Parser.parse!(%{
          "type" => "enum",
          "name" => "bang!",
          "symbols" => ["one"]
        })
      end
    end

    test "must have a valid namespace" do
      message =
        "Invalid name `.namespace` for `namespace` in %{\"name\" => \"name\", \"namespace\" => \".namespace\", \"symbols\" => [\"one\"], \"type\" => \"enum\"}"

      assert_raise AvroEx.Schema.DecodeError, message, fn ->
        Parser.parse!(%{
          "type" => "enum",
          "name" => "name",
          "namespace" => ".namespace",
          "symbols" => ["one"]
        })
      end
    end

    test "symbols must by alphanumberic or underscores, and not start with a number" do
      message_1 =
        "Invalid name `1` for `symbols` in %{\"name\" => \"non_string\", \"symbols\" => [1], \"type\" => \"enum\"}"

      assert_raise AvroEx.Schema.DecodeError, message_1, fn ->
        Parser.parse!(%{
          "type" => "enum",
          "name" => "non_string",
          "symbols" => [1]
        })
      end

      message_2 =
        "Invalid name `abcABC!` for `symbols` in %{\"name\" => \"bad_name_1\", \"symbols\" => [\"abcABC!\"], \"type\" => \"enum\"}"

      assert_raise AvroEx.Schema.DecodeError, message_2, fn ->
        Parser.parse!(%{
          "type" => "enum",
          "name" => "bad_name_1",
          "symbols" => ["abcABC!"]
        })
      end

      message_3 =
        "Invalid name `1a` for `symbols` in %{\"name\" => \"bad_name_2\", \"symbols\" => [\"1a\"], \"type\" => \"enum\"}"

      assert_raise AvroEx.Schema.DecodeError, message_3, fn ->
        Parser.parse!(%{
          "type" => "enum",
          "name" => "bad_name_2",
          "symbols" => ["1a"]
        })
      end
    end
  end

  describe "arrays" do
    test "can parse basic arrays" do
      assert %Schema{schema: schema, context: context} =
               Parser.parse!(%{
                 "type" => "array",
                 "items" => "string"
               })

      assert schema == %Array{items: %Primitive{type: :string}, default: []}
      assert context == %Context{}
    end

    test "can have defaults" do
      assert %Schema{schema: schema, context: context} =
               Parser.parse!(%{
                 "type" => "array",
                 "items" => "int",
                 "default" => [1, 2, 3]
               })

      assert schema == %Array{items: %Primitive{type: :int}, default: [1, 2, 3]}
      assert context == %Context{}
    end

    test "default must be a valid array of that type" do
      message_1 = "Invalid default in Array<items=int> Schema Mismatch: Expected value of int, got \"one\""

      assert_raise AvroEx.Schema.DecodeError, message_1, fn ->
        Parser.parse!(%{
          "type" => "array",
          "items" => "int",
          "default" => ["one", "two", "three"]
        })
      end

      message_2 = "Invalid default in Array<items=int> Schema Mismatch: Expected value of Array<items=int>, got 1"

      assert_raise AvroEx.Schema.DecodeError, message_2, fn ->
        Parser.parse!(%{
          "type" => "array",
          "items" => "int",
          "default" => 1
        })
      end
    end
  end

  describe "fixed" do
    test "can parse basic fixed" do
      assert %Schema{schema: schema, context: context} =
               Parser.parse!(%{
                 "name" => "double",
                 "namespace" => "one.two.three",
                 "doc" => "two numbers",
                 "aliases" => ["dos_nums"],
                 "type" => "fixed",
                 "size" => 2,
                 "extra" => "val"
               })

      assert schema == %Fixed{
               name: "double",
               namespace: "one.two.three",
               size: 2,
               doc: "two numbers",
               aliases: ["dos_nums"],
               metadata: %{"extra" => "val"}
             }

      assert context == %Context{
               names: %{
                 "one.two.three.double" => schema,
                 "one.two.three.dos_nums" => schema
               }
             }
    end

    test "must include size" do
      message_1 =
        "Schema missing required key `size` for AvroEx.Schema.Fixed in %{\"name\" => \"missing_size\", \"type\" => \"fixed\"}"

      assert_raise AvroEx.Schema.DecodeError, message_1, fn ->
        Parser.parse!(%{
          "type" => "fixed",
          "name" => "missing_size"
        })
      end

      message_2 =
        "Expected `size` to be integer got \"40\" in %{\"name\" => \"string_size\", \"size\" => \"40\", \"type\" => \"fixed\"}"

      assert_raise AvroEx.Schema.DecodeError, message_2, fn ->
        Parser.parse!(%{
          "type" => "fixed",
          "name" => "string_size",
          "size" => "40"
        })
      end
    end

    test "must have a valid name" do
      message = "Invalid name `1bad` for `name` in %{\"name\" => \"1bad\", \"size\" => 2, \"type\" => \"fixed\"}"

      assert_raise AvroEx.Schema.DecodeError, message, fn ->
        Parser.parse!(%{
          "type" => "fixed",
          "name" => "1bad",
          "size" => 2
        })
      end
    end

    test "must have a valid namespace" do
      message =
        "Invalid name `namespace..` for `namespace` in %{\"name\" => \"bad_namespace\", \"namespace\" => \"namespace..\", \"size\" => 2, \"type\" => \"fixed\"}"

      assert_raise AvroEx.Schema.DecodeError, message, fn ->
        Parser.parse!(%{
          "type" => "fixed",
          "name" => "bad_namespace",
          "namespace" => "namespace..",
          "size" => 2
        })

        message =
          "Invalid name `namespace.` for `namespace` in %{\"name\" => \"bad_namespace\", \"namespace\" => \"namespace..\", \"size\" => 2, \"type\" => \"fixed\"}"

        assert_raise AvroEx.Schema.DecodeError, message, fn ->
          Parser.parse!(%{
            "type" => "fixed",
            "name" => "bad_namespace",
            "namespace" => "namespace.",
            "size" => 2
          })
        end
      end
    end
  end

  describe "maps" do
    test "can parse simple maps" do
      assert %Schema{schema: schema, context: context} =
               Parser.parse!(%{
                 "type" => "map",
                 "values" => "string",
                 "default" => %{"a" => "b"}
               })

      assert schema == %AvroMap{
               values: %Primitive{type: :string},
               default: %{"a" => "b"}
             }

      assert context == %Context{}
    end

    test "default must be encodeable" do
      message_1 = "Invalid default in Map<values=string> Schema Mismatch: Expected value of string, got 1"

      assert_raise AvroEx.Schema.DecodeError, message_1, fn ->
        Parser.parse!(%{
          "type" => "map",
          "values" => "string",
          "default" => %{"a" => 1}
        })
      end

      message_2 = "Invalid default in Map<values=string> Schema Mismatch: Expected value of Map<values=string>, got []"

      assert_raise AvroEx.Schema.DecodeError, message_2, fn ->
        Parser.parse!(%{
          "type" => "map",
          "values" => "string",
          "default" => []
        })
      end
    end

    test "values must be a valid type" do
      message = "Found undeclared reference `nope`. Known references are empty"

      assert_raise AvroEx.Schema.DecodeError, message, fn ->
        Parser.parse!(%{
          "type" => "map",
          "values" => "nope"
        })
      end
    end
  end

  describe "name references" do
    test "types can be referred to by an previously defined type" do
      assert %Schema{schema: schema, context: context} =
               Parser.parse!(%{
                 "type" => "record",
                 "name" => "pets",
                 "fields" => [
                   %{
                     "name" => "favorite_pet",
                     "type" => %{
                       "type" => "record",
                       "name" => "Pet",
                       "fields" => [
                         %{
                           "name" => "type",
                           "type" => %{"type" => "enum", "name" => "PetType", "symbols" => ["cat", "dog"]}
                         },
                         %{"name" => "name", "type" => "string"}
                       ]
                     }
                   },
                   %{"name" => "first_pet", "type" => "Pet"}
                 ]
               })

      assert %Record{
               name: "pets",
               fields: [
                 %Record.Field{
                   name: "favorite_pet",
                   type: %Record{
                     name: "Pet",
                     fields: [
                       %Record.Field{
                         name: "type",
                         type: %AvroEnum{name: "PetType", symbols: ["cat", "dog"]}
                       },
                       %Record.Field{name: "name", type: %Primitive{type: :string}}
                     ]
                   }
                 },
                 %Record.Field{name: "first_pet", type: %Reference{type: "Pet"}}
               ]
             } = schema

      assert Map.keys(context.names) == ["Pet", "PetType", "pets"]
    end

    test "types can be referred by an alias" do
      assert %Schema{schema: schema, context: context} =
               Parser.parse!(%{
                 "type" => "record",
                 "name" => "top",
                 "fields" => [
                   %{
                     "name" => "one",
                     "type" => %{"type" => "enum", "symbols" => ["x"], "name" => "a", "aliases" => ["b", "c"]}
                   },
                   %{"name" => "two", "type" => "a"},
                   %{"name" => "three", "type" => "b"},
                   %{"name" => "four", "type" => "c"}
                 ]
               })

      assert schema == %Record{
               fields: [
                 %AvroEx.Schema.Record.Field{
                   name: "one",
                   type: %AvroEx.Schema.Enum{
                     aliases: ["b", "c"],
                     name: "a",
                     symbols: ["x"]
                   }
                 },
                 %AvroEx.Schema.Record.Field{
                   name: "two",
                   type: %AvroEx.Schema.Reference{type: "a"}
                 },
                 %AvroEx.Schema.Record.Field{
                   name: "three",
                   type: %AvroEx.Schema.Reference{type: "b"}
                 },
                 %AvroEx.Schema.Record.Field{
                   name: "four",
                   type: %AvroEx.Schema.Reference{type: "c"}
                 }
               ],
               name: "top"
             }

      assert Map.keys(context.names) == ["a", "b", "c", "top"]
    end

    test "can create recursive types" do
      assert %Schema{schema: schema} =
               Parser.parse!(%{
                 "type" => "record",
                 "name" => "recursive",
                 "fields" => [
                   %{"name" => "nested", "type" => ["null", "recursive"]}
                 ]
               })

      assert schema == %Record{
               name: "recursive",
               fields: [
                 %Record.Field{
                   name: "nested",
                   type: %Union{possibilities: [%Primitive{type: :null}, %Reference{type: "recursive"}]}
                 }
               ]
             }
    end

    test "aliases must be valid" do
      message_1 =
        "Invalid name `` for `aliases` in %{\"aliases\" => \"\", \"fields\" => [%{\"name\" => \"one\", \"type\" => \"string\"}], \"name\" => \"invalid_aliases\", \"type\" => \"record\"}"

      assert_raise AvroEx.Schema.DecodeError, message_1, fn ->
        Parser.parse!(%{
          "type" => "record",
          "name" => "invalid_aliases",
          "aliases" => "",
          "fields" => [%{"name" => "one", "type" => "string"}]
        })
      end

      message_2 =
        "Invalid name `bad name` for `aliases` in %{\"aliases\" => [\"bad name\"], \"fields\" => [%{\"name\" => \"one\", \"type\" => \"string\"}], \"name\" => \"invalid_aliases\", \"type\" => \"record\"}"

      assert_raise AvroEx.Schema.DecodeError, message_2, fn ->
        Parser.parse!(%{
          "type" => "record",
          "name" => "invalid_aliases",
          "aliases" => ["bad name"],
          "fields" => [%{"name" => "one", "type" => "string"}]
        })
      end
    end

    test "must refer to types previously defined" do
      message = "Found undeclared reference `callback`. Known references are `invalid_ref`"

      assert_raise AvroEx.Schema.DecodeError, message, fn ->
        Parser.parse!(%{
          "type" => "record",
          "name" => "invalid_ref",
          "fields" => [
            %{"name" => "one", "type" => "callback"},
            %{"name" => "two", "type" => %{"name" => "callback", "type" => "fixed", "size" => 2}}
          ]
        })
      end
    end

    test "namespaces are inherited" do
      assert %Schema{schema: schema} =
               Parser.parse!(%{
                 "type" => "record",
                 "name" => "inferred_reference",
                 "namespace" => "beam.community",
                 "fields" => [
                   %{"name" => "one", "type" => %{"name" => "callback", "type" => "fixed", "size" => 2}},
                   %{"name" => "two", "type" => "callback"}
                 ]
               })

      assert schema == %Record{
               name: "inferred_reference",
               namespace: "beam.community",
               fields: [
                 %Record.Field{name: "one", type: %Fixed{name: "callback", size: 2}},
                 %Record.Field{name: "two", type: %Reference{type: "beam.community.callback"}}
               ]
             }

      assert %Schema{schema: schema} =
               Parser.parse!(%{
                 "type" => "record",
                 "name" => "qualified_reference",
                 "namespace" => "beam.community",
                 "fields" => [
                   %{"name" => "one", "type" => %{"name" => "callback", "type" => "fixed", "size" => 2}},
                   %{"name" => "two", "type" => "beam.community.callback"}
                 ]
               })

      assert schema == %Record{
               name: "qualified_reference",
               namespace: "beam.community",
               fields: [
                 %Record.Field{name: "one", type: %Fixed{name: "callback", size: 2}},
                 %Record.Field{name: "two", type: %Reference{type: "beam.community.callback"}}
               ]
             }

      assert %Schema{schema: schema} =
               Parser.parse!(%{
                 "type" => "record",
                 "name" => "aliased_reference",
                 "namespace" => "beam.community",
                 "fields" => [
                   %{
                     "name" => "one",
                     "type" => %{"name" => "callback", "aliases" => ["alias"], "type" => "fixed", "size" => 2}
                   },
                   %{"name" => "two", "type" => "beam.community.alias"}
                 ]
               })

      assert schema == %Record{
               name: "aliased_reference",
               namespace: "beam.community",
               fields: [
                 %Record.Field{name: "one", type: %Fixed{name: "callback", size: 2, aliases: ["alias"]}},
                 %Record.Field{name: "two", type: %Reference{type: "beam.community.alias"}}
               ]
             }

      assert %Schema{schema: schema} =
               Parser.parse!(%{
                 "type" => "record",
                 "name" => "beam.community.from_name",
                 "namespace" => "ignore",
                 "fields" => [
                   %{
                     "name" => "one",
                     "type" => %{"name" => "callback", "aliases" => ["alias"], "type" => "fixed", "size" => 2}
                   },
                   %{"name" => "two", "type" => "beam.community.alias"}
                 ]
               })

      assert schema == %Record{
               name: "beam.community.from_name",
               namespace: "ignore",
               fields: [
                 %Record.Field{name: "one", type: %Fixed{name: "callback", size: 2, aliases: ["alias"]}},
                 %Record.Field{name: "two", type: %Reference{type: "beam.community.alias"}}
               ]
             }
    end
  end

  describe "strict parsing" do
    test "logicalType on a field will raise" do
      message =
        "Unrecognized schema key `logicalType` for AvroEx.Schema.Record.Field in %{\"logicalType\" => \"timestamp-millis\", \"name\" => \"timestamp\", \"type\" => \"long\"}"

      assert_raise AvroEx.Schema.DecodeError, message, fn ->
        Parser.parse!(
          %{
            "type" => "record",
            "name" => "analytics",
            "fields" => [
              %{"name" => "timestamp", "type" => "long", "logicalType" => "timestamp-millis"}
            ]
          },
          strict: true
        )
      end
    end

    test "extra fields on enum will raise" do
      message =
        "Unrecognized schema key `extra` for AvroEx.Schema.Enum in %{\"extra\" => \"value\", \"name\" => \"extra_enum\", \"symbols\" => [\"one\", \"two\"], \"type\" => \"enum\"}"

      assert_raise AvroEx.Schema.DecodeError, message, fn ->
        Parser.parse!(
          %{
            "type" => "enum",
            "name" => "extra_enum",
            "symbols" => ["one", "two"],
            "extra" => "value"
          },
          strict: true
        )
      end
    end

    test "extra fields on fixed will raise" do
      message =
        "Unrecognized schema key `extra` for AvroEx.Schema.Fixed in %{\"extra\" => \"value\", \"name\" => \"double\", \"size\" => 2, \"type\" => \"fixed\"}"

      assert_raise AvroEx.Schema.DecodeError, message, fn ->
        Parser.parse!(
          %{
            "type" => "fixed",
            "size" => 2,
            "name" => "double",
            "extra" => "value"
          },
          strict: true
        )
      end
    end
  end
end
