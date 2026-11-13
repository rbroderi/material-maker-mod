"""A recording fake of Unreal's Python API and of Material Maker's mm.py, to run the
scripts exported by the Unreal export targets outside Unreal.

Usage: python voxel_unreal_stub.py <exported .py> [--quiet]

The script is executed with fake `unreal` and `mm` modules that record the nodes
it creates, their properties and the connections it makes. Then, for a voxel
export, the stub asserts that a Custom expression received the inputs of the
Custom node contract and that MP_NORMAL was connected. It prints OK on success
and exits with a non-zero status on failure.

The stub proves only that the script runs and wires what it intends: the names
of the Unreal API it uses are not checked against a real Unreal.
"""
import importlib
import sys
import types

CONTRACT_INPUTS = ['Position', 'Normal', 'Seed', 'Age', 'Upkeep', 'Fresh', 'Char', 'Wet',
                   'Axis', 'Origin', 'Footprint', 'Time']


class Proxy:
    """Any attribute or call of the fake unreal module: records its name and arguments"""

    def __init__(self, name, args=(), kwargs=None):
        self._name = name
        self._args = args
        self._kwargs = kwargs or {}

    def __getattr__(self, attr):
        if attr.startswith('__'):
            raise AttributeError(attr)
        return Proxy(self._name + '.' + attr)

    def __call__(self, *args, **kwargs):
        return Proxy(self._name, args, kwargs)

    def __iter__(self):
        return iter(())

    def __str__(self):
        return self._name

    def __repr__(self):
        return 'Proxy(%s)' % self._name


class FakeCustomInput:
    def __init__(self, name):
        self.input_name = name


class FakeCustomOutput:
    def __init__(self, name, size):
        self.output_name = name
        self.size = size


class FakeNode:
    def __init__(self, node_type, x, y):
        self.type = node_type
        self.x = x
        self.y = y
        self.props = {}

    def set_editor_property(self, name, value):
        self.props[name] = value

    def get_editor_property(self, name):
        return self.props.get(name)

    def __repr__(self):
        return 'Node(%s)' % self.type


class FakeMaterial:
    last = None

    def __init__(self, name, create=False):
        self.name = name
        self.nodes = []
        self.props = {}
        self.node_connections = []      # (source, source_output, dest, dest_input)
        self.property_connections = []  # (source, source_output, property name)
        self.saved = False
        FakeMaterial.last = self

    def clear(self):
        self.nodes = []

    def save(self):
        self.saved = True

    def set_editor_property(self, name, value):
        self.props[name] = value

    def add_node(self, node_type, x=0, y=0):
        node = FakeNode(node_type, x, y)
        self.nodes.append(node)
        return node

    def connect_property(self, source, source_output, prop):
        self.property_connections.append((source, source_output, str(prop)))
        return True

    def connect_nodes(self, source, source_output, dest, dest_input):
        self.node_connections.append((source, source_output, dest, dest_input))
        return True


class FakeMaterialEditingLibrary:
    """Records the calls of unreal.MaterialEditingLibrary that a Material Function
    script makes (create_material_expression_in_function and friends)"""
    nodes = []
    connections = []   # (source, source_output, dest, dest_input)
    updated = []
    used = False

    @classmethod
    def reset(cls):
        cls.nodes = []
        cls.connections = []
        cls.updated = []
        cls.used = False

    @classmethod
    def create_material_expression_in_function(cls, function, expression_class, x=0, y=0):
        cls.used = True
        node = FakeNode(str(expression_class).replace('unreal.MaterialExpression', ''), x, y)
        cls.nodes.append(node)
        return node

    @classmethod
    def connect_material_expressions(cls, source, source_output, dest, dest_input):
        cls.used = True
        cls.connections.append((source, source_output, dest, dest_input))
        return True

    @classmethod
    def update_material_function(cls, function):
        cls.used = True
        cls.updated.append(function)


def install_fakes():
    unreal = types.ModuleType('unreal')
    unreal.__getattr__ = lambda attr: Proxy('unreal.' + attr)
    FakeMaterialEditingLibrary.reset()
    unreal.MaterialEditingLibrary = FakeMaterialEditingLibrary
    sys.modules['unreal'] = unreal

    mm = types.ModuleType('mm')
    mm.Material = FakeMaterial
    mm.custom_input = FakeCustomInput
    mm.custom_output = FakeCustomOutput

    def read_text_file(path):
        try:
            with open(path, 'r') as f:
                return f.read()
        except OSError:
            return ''
    mm.read_text_file = read_text_file
    mm.import_texture = lambda src, dest: Proxy('texture_asset')
    mm.import_data_texture = mm.import_texture
    mm.get_object_from_path = lambda p: Proxy('object')
    sys.modules['mm'] = mm
    # the exported script reloads mm, that is not a module with a file
    importlib.reload = lambda module: module


def fail(message):
    print('FAIL: ' + message)
    sys.exit(1)


def check_voxel(mat):
    customs = [n for n in mat.nodes if n.type == 'Custom']
    if len(customs) != 1:
        fail('expected one Custom expression, found %d' % len(customs))
    custom = customs[0]
    inputs = [i.input_name for i in custom.props.get('inputs', [])]
    if len(inputs) < 12:
        fail('the Custom expression received %d inputs (12 or more expected)' % len(inputs))
    if inputs[:12] != CONTRACT_INPUTS:
        fail('input names %s differ from the contract %s' % (inputs[:12], CONTRACT_INPUTS))
    if not custom.props.get('code'):
        fail('the Custom expression has no code')
    connected = [c[3] for c in mat.node_connections if c[2] is custom]
    for name in inputs:
        if name not in connected:
            fail('Custom input %s is not connected' % name)
    normal_connections = [c for c in mat.property_connections if c[2].endswith('MP_NORMAL')]
    if not normal_connections:
        fail('MP_NORMAL is not connected')
    if mat.props.get('tangent_space_normal') is not False:
        fail('tangent_space_normal is not set to False')
    # the normal comes from the Custom expression, through the inverse transpose
    # transform (Transform + DotProduct + AppendVector + Normalize nodes)
    source = normal_connections[0][0]
    reached = set()
    todo = [source]
    while todo:
        node = todo.pop()
        if id(node) in reached:
            continue
        reached.add(id(node))
        todo.extend(c[0] for c in mat.node_connections if c[2] is node)
    if id(custom) not in reached:
        fail('MP_NORMAL is not fed by the Custom expression output')
    if source.type != 'Normalize':
        fail('MP_NORMAL is not normalized (%s)' % source.type)
    kinds = {}
    for n in mat.nodes:
        if id(n) in reached:
            kinds[n.type] = kinds.get(n.type, 0) + 1
    if kinds.get('DotProduct') != 6 or kinds.get('Transform') != 6 or kinds.get('Normalize') != 2:
        fail('the normal is not transformed with the inverse transpose (3 basis vectors in each direction): %s' % kinds)
    # the Normal input of the Custom expression is made the same way, from the world normal
    normal_in = [c[0] for c in mat.node_connections if c[2] is custom and c[3] == 'Normal']
    if len(normal_in) != 1 or normal_in[0].type != 'Normalize':
        fail('the Normal input of the Custom expression is not a normalized inverse transpose transform')
    if not mat.saved:
        fail('the material was not saved')


FUNCTION_OUTPUTS = ['BaseColor', 'Metallic', 'Roughness', 'Normal', 'Emissive', 'AmbientOcclusion', 'Opacity']


def check_function():
    mel = FakeMaterialEditingLibrary
    customs = [n for n in mel.nodes if n.type == 'Custom']
    if len(customs) != 1:
        fail('expected one Custom expression in the function, found %d' % len(customs))
    custom = customs[0]
    inputs = [i.input_name for i in custom.props.get('inputs', [])]
    if inputs[:12] != CONTRACT_INPUTS:
        fail('input names %s differ from the contract %s' % (inputs[:12], CONTRACT_INPUTS))
    if not custom.props.get('code'):
        fail('the Custom expression has no code')
    function_inputs = [n for n in mel.nodes if n.type == 'FunctionInput']
    names = [n.props.get('input_name') for n in function_inputs]
    if names != CONTRACT_INPUTS:
        fail('function inputs %s differ from the contract %s' % (names, CONTRACT_INPUTS))
    for n in function_inputs:
        if not any(c[0] is n and c[2] is custom and c[3] == n.props['input_name'] for c in mel.connections):
            fail('function input %s is not connected to the Custom expression' % n.props['input_name'])
    function_outputs = [n for n in mel.nodes if n.type == 'FunctionOutput']
    names = [n.props.get('output_name') for n in function_outputs]
    if names != FUNCTION_OUTPUTS:
        fail('function outputs %s differ from %s' % (names, FUNCTION_OUTPUTS))
    for n in function_outputs:
        if not any(c[0] is custom and c[2] is n for c in mel.connections):
            fail('function output %s is not fed by the Custom expression' % n.props['output_name'])
    if not mel.updated:
        fail('update_material_function was not called')


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    if len(args) != 1:
        print('usage: voxel_unreal_stub.py <exported .py>')
        sys.exit(2)
    install_fakes()
    with open(args[0], 'r') as f:
        source = f.read()
    exec(compile(source, args[0], 'exec'), {'__name__': '__main__'})
    if FakeMaterialEditingLibrary.used:
        # a Material Function script
        check_function()
        print('OK')
        return
    mat = FakeMaterial.last
    if mat is None:
        fail('the script did not create a material')
    check_voxel(mat)
    print('OK')


if __name__ == '__main__':
    main()
