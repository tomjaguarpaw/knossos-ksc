import ksc
from ksc.type import Type
from ksc.tracing import node
from ksc.tracing.jitting import make_edef
from ksc.utils import ShapeType
from ksc.tracing.function import Trace, TraceableFunction
from ksc.tracing.functions.type_propagation_rules import (
    elementwise,
    first_arg,
    flatten_type_prop_rule,
    keep_shape_prop_rule
)

add = make_edef("add", ["a", "b"], elementwise)

sub = make_edef("sub", ["a", "b"], elementwise)

mul = make_edef("mul", ["a", "b"], elementwise)

div = make_edef("div", ["a", "b"], elementwise)

flatten = make_edef("flatten", ["x"], flatten_type_prop_rule)

to_float = make_edef("to_float", ["x"], keep_shape_prop_rule(Type.Float))

def get_tuple_element(index, x):
    size = len(x)
    def shape_prop_function(arg):
        x_shape, x_type = arg.shape_type
        return ShapeType(x_shape[index], x_type.children[index])
    class GetTupleElement(TraceableFunction):
        is_edef = False
        is_builtin = True
        def __init__(self):
            super().__init__(f"get${index+1}${size}", arg_names=["x"])
        def trace(self, *args):
            assert len(args) == 1
            o_shape, o_type = shape_prop_function(args[0])
            body = node.Node(
                name=self.name,
                shape=o_shape,
                type=o_type,
                children=args,
                shape_prop_function=shape_prop_function)
            shape_types = tuple(arg.shape_type for arg in args)
            return Trace(body, ShapeType(o_shape, o_type), shape_types)
    return GetTupleElement()(x)