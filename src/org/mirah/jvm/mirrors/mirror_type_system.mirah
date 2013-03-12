# Copyright (c) 2012 The Mirah project authors. All Rights Reserved.
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

package org.mirah.jvm.mirrors

import java.util.ArrayList
import java.util.LinkedList
import java.util.List
import java.util.logging.Logger

import org.jruby.org.objectweb.asm.Opcodes
import org.jruby.org.objectweb.asm.Type

import mirah.lang.ast.Position
import mirah.lang.ast.ClassDefinition

import org.mirah.typer.AssignableTypeFuture
import org.mirah.typer.BaseTypeFuture
import org.mirah.typer.CallFuture
import org.mirah.typer.DelegateFuture
import org.mirah.typer.ErrorType
import org.mirah.typer.MethodFuture
import org.mirah.typer.MethodType
import org.mirah.typer.ResolvedType
import org.mirah.typer.TypeFuture
import org.mirah.typer.TypeSystem
import org.mirah.typer.simple.SimpleScope

import org.mirah.jvm.types.JVMType
import org.mirah.jvm.types.MemberKind

class MirrorTypeSystem implements TypeSystem
  def initialize(classloader:ClassLoader = MirrorTypeSystem.class.getClassLoader)
    @loader = SimpleAsyncMirrorLoader.new(AsyncLoaderAdapter.new(
        BytecodeMirrorLoader.new(classloader, PrimitiveLoader.new)))
    @object_future = wrap(Type.getType('Ljava/lang/Object;'))
    @object = BaseType(@object_future.resolve)
    @main_type = TypeFuture(nil)
    @primitives = {
      boolean: 'Z',
      byte: 'B',
      char: 'C',
      short: 'S',
      int: 'I',
      long: 'J',
      float: 'F',
      double: 'D',
      void: 'V',
    }
  end

  def self.initialize:void
    @@log = Logger.getLogger(MirrorTypeSystem.class.getName)
  end

  def getSuperClass(type)
    future = BaseTypeFuture.new
    if type.kind_of?(BaseTypeFuture)
      future.position = BaseTypeFuture(type).position
    end
    type.onUpdate do |x, resolved|
      if resolved.isError
        future.resolved(resolved)
      else
        future.resolved(JVMType(resolved).superclass)
      end
    end
    future
  end

  def getMainType(scope, script)
    @main_type ||= defineType(scope, script, "FooBar", nil, [])
  end

  def addDefaultImports(scope)
  end

  def getFixnumType(value)
    wrap(Type.getType("I"))
  end

  def getFloatType(value)
    wrap(Type.getType("D"))
  end

  def getVoidType
    @void ||= wrap(Type.getType("V"))
  end

  def getBooleanType
    wrap(Type.getType("Z"))
  end

  def getImplicitNilType
    getVoidType
  end

  def getStringType
    wrap(Type.getType("Ljava/lang/String;"))
  end

  def getRegexType
    wrap(Type.getType("Ljava/util/regex/Pattern;"))
  end

  def getBaseExceptionType
    wrap(Type.getType("Ljava/lang/Throwable;"))
  end

  def getDefaultExceptionType
    wrap(Type.getType("Ljava/lang/Exception;"))
  end

  def getArrayLiteralType(valueType, position)
    wrap(Type.getType("Ljava/util/List;"))
  end

  def getHashLiteralType(keyType, valueType, position)
    wrap(Type.getType("Ljava/util/HashMap;"))
  end

  def getMethodDefType(target, name, argTypes, declaredReturnType, position)
    createMember(
        MirrorType(target.resolve), name, argTypes, declaredReturnType,
        position)
  end

  def getNullType
    @nullType ||= BaseTypeFuture.new.resolved(NullType.new)
  end

  def getMethodType(call)
    future = DelegateFuture.new()
    if call.resolved_parameters.all?
      target = MirrorType(call.resolved_target)
      future.type = MethodLookup.findMethod(
          call.scope, target, call.name,
          call.resolved_parameters, call.position) || BaseTypeFuture.new(call.position)
      target.addMethodListener(call.name) do |klass, name|
        if klass == target
          future.type = MethodLookup.findMethod(
              call.scope, target, call.name,
              call.resolved_parameters, call.position) || BaseTypeFuture.new(call.position)
        end
      end
    end
    future
  end

  def getMetaType(type:ResolvedType):ResolvedType
    if type.isError
      type
    else
      jvmType = MirrorType(type)
      if jvmType.isMeta
        jvmType
      else
        MetaType.new(jvmType)
      end
    end
  end

  def getMetaType(type:TypeFuture):TypeFuture
    future = BaseTypeFuture.new
    types = TypeSystem(self)
    type.onUpdate do |x, resolved|
      future.resolved(types.getMetaType(resolved))
    end
    future
  end

  def getLocalType(scope, name, position)
    @local ||= AssignableTypeFuture.new(position)
  end

  def defineType(scope, node, name, superclass, interfaces)
    position = node ? node.position : nil
    type = Type.getObjectType(name.replace(?., ?/))
    superclass ||= @object_future
    interfaceArray = TypeFuture[interfaces.size]
    interfaces.toArray(interfaceArray)
    mirror = MirahMirror.new(type, Opcodes.ACC_PUBLIC,
                             superclass, interfaceArray)
    future = MirrorFuture.new(mirror, position)
    @loader.defineMirror(type, future)
    future
  end

  def get(scope, typeref)
    desc = @primitives[typeref.name]
    type = if desc
      Type.getType(String(desc))
    else
      Type.getObjectType(typeref.name)
    end
    @loader.loadMirrorAsync(type)
  end

  def wrap(type:Type):TypeFuture
    @loader.loadMirrorAsync(type)
  end

  def createMember(target:MirrorType, name:String, arguments:List,
                   returnType:TypeFuture, position:Position):MethodFuture
    returnFuture = AssignableTypeFuture.new(position)

    flags = Opcodes.ACC_PUBLIC
    kind = MemberKind.METHOD
    if target.isMeta
      target = MirrorType(MetaType(target).unmeta)
      flags |= Opcodes.ACC_STATIC
      kind = MemberKind.STATIC_METHOD
    end
    member = AsyncMember.new(flags, target, name, arguments, returnFuture, kind)

    returnFuture.error_message =
        "Cannot determine return type for method #{member}"
    returnFuture.declare(returnType, position) if returnType

    target.add(member)

    MethodFuture.new(name, member.argumentTypes, returnFuture, false, position)
  end

  def self.main(args:String[]):void
    types = MirrorTypeSystem.new
    scope = SimpleScope.new
    main_type = types.getMainType(nil, nil)
    scope.selfType_set(main_type)

    super_future = BaseTypeFuture.new
    b = types.defineType(scope, ClassDefinition.new, "B", super_future, [])
    c = types.defineType(scope, ClassDefinition.new, "C", nil, [])
    types.getMethodDefType(main_type, 'foobar', [c], types.getVoidType, nil)
    type = CallFuture.new(types, scope, main_type, 'foobar', [b], [], nil)
    puts type.resolve
    super_future.resolved(c.resolve)
    puts type.resolve
  end
end

class FakeMember < Member
  def self.create(types:MirrorTypeSystem, description:String, flags:int=-1)
    m = /^(@)?([^.]+)\.(.+)$/.matcher(description)
    unless m.matches
      raise IllegalArgumentException, "Invalid method specification #{description}"
    end
    abstract = !m.group(1).nil?
    klass = wrap(types, Type.getType(m.group(2)))
    method = Type.getType(m.group(3))
    returnType = wrap(types, method.getReturnType)
    args = LinkedList.new
    method.getArgumentTypes.each do |arg|
      args.add(wrap(types, arg))
    end
    flags = Opcodes.ACC_PUBLIC if flags == -1
    flags |= Opcodes.ACC_ABSTRACT if abstract
    FakeMember.new(description, flags, klass, returnType, args)
  end

  def self.wrap(types:MirrorTypeSystem, type:Type)
    JVMType(types.wrap(type).resolve)
  end

  def initialize(description:String, flags:int,
                 klass:JVMType, returnType:JVMType, args:List)
    super(flags, klass, 'foobar', args, returnType, MemberKind.METHOD)
    @description = description
  end

  def toString
    @description
  end
end