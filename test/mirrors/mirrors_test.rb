# Copyright (c) 2010 The Mirah project authors. All Rights Reserved.
# All contributing project authors may be found in the NOTICE file.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'test/unit'
require 'mirah'

class BaseMirrorsTest < Test::Unit::TestCase
  java_import 'org.mirah.jvm.mirrors.MirrorTypeSystem'
  java_import 'org.mirah.jvm.types.JVMType'
  java_import 'org.mirah.typer.BaseTypeFuture'
  java_import 'org.mirah.typer.CallFuture'
  java_import 'org.mirah.typer.TypeFuture'
  java_import 'org.mirah.typer.simple.SimpleScope'
  java_import 'mirah.lang.ast.ClassDefinition'
  java_import 'mirah.lang.ast.TypeRefImpl'
  java_import 'org.jruby.org.objectweb.asm.Opcodes'
  java_import 'org.jruby.org.objectweb.asm.Type'

  def setup
    @types = MirrorTypeSystem.new
    @scope = SimpleScope.new
  end

  def assert_descriptor(descriptor, type)
    assert(type.isResolved)
    assert_resolved_to(descriptor, type.resolve)
  end

  def assert_resolved_to(descriptor, resolved)
    assert_kind_of(JVMType, resolved)
    assert_equal(descriptor, resolved.getAsmType.descriptor)
  end

  def assert_error(type)
    assert_block("Excpected #{type.resolve} to be an error") {
      type.resolve.isError
    }
  end

  def assert_not_error(type)
    assert(!type.resolve.isError)
  end

  def main_type
    @types.getMainType(nil, nil)
  end
end

class MirrorsTest < BaseMirrorsTest

  def test_add_default_imports
    # Just make sure it doesn't raise an exception
    @types.addDefaultImports(@scope)
  end

  def test_fixnum
    type = @types.getFixnumType(0)
    assert_descriptor("I", type)
  end

  def test_void
    type = @types.getVoidType
    assert_descriptor("V", type)
  end

  def test_nil
    type = @types.getImplicitNilType
    assert_not_nil(type)
  end

  def test_main_type
    assert_descriptor("LFooBar;", main_type)
  end

  def test_superclass
    assert_descriptor("Ljava/lang/Object;", @types.getSuperClass(main_type))
  end

  def test_method_def
    type = @types.getMethodDefType(main_type, 'foobar', [], nil, nil)
    assert_error(type.returnType)
    type = @types.getMethodDefType(
        main_type, 'foobar', [], @types.getVoidType, nil)
    assert_descriptor('V', type.returnType)
  end

  def test_meta_resolved
    type = main_type.resolve
    assert_false(type.isMeta)
    assert(@types.getMetaType(type).isMeta)
  end

  def test_meta_future
    type = main_type
    assert_false(type.resolve.isMeta)
    assert(@types.getMetaType(type).resolve.isMeta)
  end

  def test_local
    type1 = @types.getLocalType(@scope, "ARGV", nil)
    type2 = @types.getLocalType(@scope, "ARGV", nil)
    type2.assign(@types.getFixnumType(0), nil)
    assert_descriptor("I", type1)
    assert_descriptor("I", type2)
  end

  def test_define_type
    type = @types.defineType(
        @scope, ClassDefinition.new, "Subclass", main_type, [])
    assert_descriptor("LSubclass;", type)
    assert_descriptor("LFooBar;", @types.getSuperClass(type))
  end

  def test_redefine_main_type
    type = @types.defineType(@scope, ClassDefinition.new, "FooBar", nil, [])
    assert_descriptor("LFooBar;", type)
  end

  def test_default_constructor
    object = @types.getSuperClass(main_type).resolve
    constructor = object.getMethod('<init>', [])
    assert_not_nil(constructor)
    assert_equal('CONSTRUCTOR', constructor.kind.name)
    assert_not_equal(0, constructor.flags & Opcodes.ACC_PUBLIC)
  end

  def test_get
    type = @types.get(@scope, TypeRefImpl.new('void', false, false, nil))
    assert_descriptor('V', type)
  end
end

class MTS_MethodLookupTest < BaseMirrorsTest
  def setup
    super
    @scope.selfType_set(main_type)
  end


  def test_simple_method_def
    @types.getMethodDefType(main_type, 'foobar', [], @types.getVoidType, nil)
    type = @types.getMethodType(
        CallFuture.new(@types, @scope, main_type, 'foobar', [], [], nil))
    assert_resolved_to('V', type.resolve.returnType)
  end

  def test_multiple_method_defs
    @types.getMethodDefType(main_type, 'foobar', [], @types.getVoidType, nil)
    @types.getMethodDefType(main_type, 'foo', [], @types.getFixnumType(1), nil)
    type = @types.getMethodType(
        CallFuture.new(@types, @scope, main_type, 'foobar', [], [], nil))
    assert_not_error(type)
    assert_resolved_to('V', type.resolve.returnType)
    type = @types.getMethodType(
        CallFuture.new(@types, @scope, main_type, 'foo', [], [], nil))
    assert_not_error(type)
    assert_resolved_to('I', type.resolve.returnType)
  end

  def test_async_return_type
    future = BaseTypeFuture.new
    @types.getMethodDefType(main_type, 'foo', [], future, nil)
    type = @types.getMethodType(
        CallFuture.new(@types, @scope, main_type, 'foo', [], [], nil))
    assert_error(type)
    future.resolved(@types.getFixnumType(1).resolve)
    assert_not_error(type)
    assert_resolved_to('I', type.resolve.returnType)
  end

  def test_infer_return_type_from_body
    future = @types.getMethodDefType(main_type, 'foo', [], nil, nil)
    type = @types.getMethodType(
        CallFuture.new(@types, @scope, main_type, 'foo', [], [], nil))
    assert_error(type)
    future.returnType.assign(@types.getFixnumType(1), nil)
    assert_not_error(type)
    assert_resolved_to('I', type.resolve.returnType)
  end

  def test_async_arguments
    int = @types.wrap(Type.getType("I"))
    short = @types.wrap(Type.getType("S"))
    @types.getMethodDefType(main_type, 'foo', [int], int, nil)
    argument_future = BaseTypeFuture.new
    @types.getMethodDefType(main_type, 'foo', [argument_future], short, nil)

    call_future = @types.getMethodType(
        CallFuture.new(@types, @scope, main_type, 'foo', [short], [], nil))
    assert_not_error(call_future)
    assert_resolved_to('I', call_future.resolve.returnType)

    # Now make the other one more specific
    argument_future.resolved(short.resolve)
    assert_resolved_to('S', call_future.resolve.returnType)
  end
end