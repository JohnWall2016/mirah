# Copyright (c) 2015 The Mirah project authors. All Rights Reserved.
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

package org.mirah.typer

import java.util.*
import org.mirah.util.Logger
import mirah.lang.ast.*
import mirah.impl.MirahParser
import org.mirah.macros.JvmBackend
import org.mirah.macros.MacroBuilder

import org.mirah.jvm.types.JVMTypeUtils
import org.mirah.jvm.types.JVMType
import org.mirah.jvm.mirrors.*

# Type inference engine.
# Makes a single pass over the AST nodes building a graph of the type
# dependencies. Whenever a new type is learned or a type changes any dependent
# types get updated.
#
# An important feature is that types will change over time.
# The first time an assignment to a variable resolves, the typer will pick that
# type for the variable. When a new assignment resolves, two things can happen:
#  - if the assigned type is compatible with the old, just continue.
#  - otherwise, widen the inferred type to include both and update any dependencies.
# This also allows the typer to handle recursive calls. Consider fib for example:
#   def fib(i:int); if i < 2 then 1 else fib(i - 1) + fib(i - 2) end; end
# The type of fib() depends on the if statement, which also depends on the type
# of fib(). The first branch infers first though, marking the if statement
# as type 'int'. This updates fib() to also be type 'int'. This in turn causes
# the if statement to check that both its branches are compatible, and they are
# so the method is resolved.
#
# Some nodes can have multiple meanings. For example, a VCall could mean a
# LocalAccess or a FunctionalCall. The typer will try each possibility,
# and update the AST tree with the one that doesn't infer as an error. There
# is always a priority implied when multiple options succeed. For example,
# a LocalAccess always wins over a FunctionalCall.
#
# This typer is type system independent. It relies on a TypeSystem and a Scoper
# to provide the types for methods, literals, variables, etc.
class Typer < SimpleNodeVisitor
  def self.initialize:void
    @@log = Logger.getLogger(Typer.class.getName)
  end

  def initialize(types: TypeSystem,
                 scopes: Scoper,
                 jvm_backend: JvmBackend,
                 parser: MirahParser=nil)
    @trueobj = java::lang::Boolean.valueOf(true)
    @futures = HashMap.new
    @types = types
    @scopes = scopes
    @macros = MacroBuilder.new(self, jvm_backend, parser)
    
    # might want one of these for each script
    @closures = BetterClosureBuilder.new(self, @macros)
  end

  def finish_closures
    @closures.finish
  end

  def macro_compiler
    @macros
  end

  def macro_compiler=(compiler:MacroBuilder)
    @macros = compiler
  end

  def type_system
    @types
  end

  def scoper
    @scopes
  end

  def getInferredType(node:Node)
    TypeFuture(@futures[node])
  end

  def inferTypeName(node:TypeName)
    @futures[node] ||= getTypeOf(node, node.typeref)
    TypeFuture(@futures[node])
  end

  def learnType(node:Node, type:TypeFuture):void
    existing = @futures[node]
    raise IllegalArgumentException, "had existing type #{existing}" if existing
    @futures[node] = type
  end

  def infer(node:Node, expression:boolean=true)
    @@log.entering("Typer", "infer", "infer(#{node})")

    return nil if node.nil?
    type = @futures[node]
    if type.nil?
      @@log.fine("source:\n    #{sourceContent node}")
      type = node.accept(self, expression ? @trueobj : nil)
      @futures[node] ||= type
    end
    TypeFuture(type)
  end

  def infer(node:Object, expression:boolean=true)
    infer(Node(node), expression)
  end

  def inferAll(nodes:NodeList)
    types = ArrayList.new
    nodes.each {|n| types.add(infer(n))} if nodes
    types
  end

  def inferAll(nodes:AnnotationList)
    types = ArrayList.new
    nodes.each {|n| types.add(infer(n))} if nodes
    types
  end

  def inferAll(arguments:Arguments)
    types = ArrayList.new
    arguments.required.each {|a| types.add(infer(a))} if arguments.required
    arguments.optional.each {|a| types.add(infer(a))} if arguments.optional
    types.add(infer(arguments.rest)) if arguments.rest
    arguments.required2.each {|a| types.add(infer(a))} if arguments.required2
    types.add(infer(arguments.block)) if arguments.block
    types
  end

  def inferAll(scope:Scope, typeNames:TypeNameList)
    types = ArrayList.new
    typeNames.each {|n| types.add(inferTypeName(TypeName(n)))}
    types
  end

  def defaultNode(node, expression)
    return TypeFutureTypeRef(node).type_future if node.kind_of?(TypeFutureTypeRef)
    ErrorType.new([["Inference error: unsupported node #{node}", node.position]])
  end

  def logger
    @@log
  end

  def visitVCall(call, expression)
    @@log.fine "visitVCall #{call}"
    workaroundASTBug call

    # This might be a local, method call, or primitive access,
    # so try them all.

    methodType = callMethodType call, Collections.emptyList
    targetType = infer(call.target)
    fcall = FunctionalCall.new(call.position,
                               Identifier(call.name.clone),
                               nil, nil)
    fcall.setParent(call.parent)


    methodType = callMethodType call, Collections.emptyList
    targetType = infer(call.target)
    @futures[fcall] = methodType
    @futures[fcall.target] = targetType

    proxy = ProxyNode.new(self, call)
    proxy.setChildren([LocalAccess.new(call.position, call.name),
                       fcall,
                       Constant.new(call.position, call.name)], 0)

    @futures[proxy] = proxy.inferChildren(expression != nil)
  end

  def visitFunctionalCall(call, expression)
    workaroundASTBug call
    parameters = inferParameterTypes call
    @futures[call] = methodType = callMethodType(call, parameters)

    proxy = ProxyNode.new(self, call)
    children = ArrayList.new(2)

    if call.parameters.size == 1
      # This might actually be a cast instead of a method call, so try
      # both. If the cast works, we'll go with that. If not, we'll leave
      # the method call.
      children.add(Cast.new(call.position, TypeName(call.typeref),
                            Node(call.parameters.get(0).clone)))
    end
    children.add(call)
    proxy.setChildren(children)

    @futures[proxy] = proxy.inferChildren(expression != nil)
  end

  def visitElemAssign(assignment, expression)
    value_type = infer(assignment.value)
    value = assignment.value
    assignment.removeChild(value)
    if value_type.kind_of?(NarrowingTypeFuture)
      narrowingCall(scopeOf(assignment),
                    infer(assignment.target),
                    '[]=',
                    inferAll(assignment.args),
                    NarrowingTypeFuture(value_type),
                    assignment.position)
    end
    call = Call.new(assignment.position, assignment.target, SimpleString.new('[]='), nil, nil)
    call.parameters = assignment.args
    if expression
      temp = scopeOf(assignment).temp('val')
      call.parameters.add(LocalAccess.new(SimpleString.new(temp)))
      newNode = Node(NodeList.new([
        LocalAssignment.new(SimpleString.new(temp), value),
        call,
        LocalAccess.new(SimpleString.new(temp))
      ]))
    else
      call.parameters.add(value)
      newNode = Node(call)
    end
    newNode = replaceSelf(assignment, newNode)
    infer(newNode)
  end

  def visitCall(call, expression)
    target = infer(call.target)
    parameters = inferParameterTypes call
    methodType = CallFuture.new(@types,
                                scopeOf(call),
                                target,
                                true,
                                parameters,
                                call)
    @futures[call] = methodType
    
    proxy = ProxyNode.new(self, call)
    children = ArrayList.new(3)
    
    is_array = '[]'.equals(call.name.identifier)
    
    if  call.parameters.size == 1
      # This might actually be a cast or array instead of a method call, so try
      # both. If the cast works, we'll go with that. If not, we'll leave
      # the method call.
      if is_array
        typeref = TypeName(call.target).typeref if call.target.kind_of?(TypeName)
      else
        typeref = call.typeref(true)
      end
      if typeref
        children.add(if is_array
          EmptyArray.new(call.position, typeref, call.parameters(0))
        else
          Cast.new(call.position, TypeName(typeref),
                   Node(call.parameters(0).clone))
        end)
      end
    end

    # Generic Type Invoking?
    if is_array
      if call.target.kind_of?(TypeName)
        typeref = TypeName(call.target).typeref
        params = ArrayList.new
        isGeneric = false
        if call.parameters and call.parameters.size > 0
          isGeneric = true
          call.parameters.each do |a|
            if isGeneric && a.kind_of?(TypeName) && TypeName(a).typeref
              params.add(TypeName(a).typeref)
            else
              isGeneric = false
            end
          end
        end
        if isGeneric
          ti = TypeInvoke.new(typeref.position, typeref, params)
          children.add(ti)
        end
      end
    end
    
    children.add(call)
    proxy.setChildren(children)

    @futures[proxy] = proxy.inferChildren(expression != nil)
  end

  def visitTypeInvoke(typeinvoke, expression)
    @types.getMetaType(getTypeOf(typeinvoke, typeinvoke.typeref))
  end

  def visitAttrAssign(call, expression)
    target = infer(call.target)
    value = infer(call.value)
    name = call.name.identifier
    setter = "#{name}_set"
    scope = scopeOf(call)
    if (value.kind_of?(NarrowingTypeFuture))
      narrowingCall(scope, target, setter, Collections.emptyList, NarrowingTypeFuture(value), call.position)
    end
    CallFuture.new(@types, scope, target, true, setter, [value], nil, call.position)
  end

  def narrowingCall(scope:Scope,
                    target:TypeFuture,
                    name:String,
                    param_types:List,
                    value:NarrowingTypeFuture,
                    position:Position):void
    # Try looking up both the wide type and the narrow type.
    wide_params = LinkedList.new(param_types)
    wide_params.add(value.wide_future)
    wide_call = CallFuture.new(@types, scope, target, true, name, wide_params, nil, position)

    narrow_params = LinkedList.new(param_types)
    narrow_params.add(value.narrow_future)
    narrow_call = CallFuture.new(@types, scope, target, true, name, narrow_params, nil, position)

    # If there's a match for the wide type (or both are errors) we always use
    # the wider one.
    wide_is_error = true
    narrow_is_error = true
    wide_call.onUpdate do |x, resolved|
      wide_is_error = resolved.isError
      if wide_is_error && !narrow_is_error
        value.narrow
      else
        value.widen
      end
    end
    narrow_call.onUpdate do |x, resolved|
      narrow_is_error = resolved.isError
      if wide_is_error && !narrow_is_error
        value.narrow
      else
        value.widen
      end
    end
  end


  def isCastable(resolved_cast_type: ResolvedType, resolved_value_type: ResolvedType): boolean
    if resolved_cast_type.kind_of?(JVMType)                   &&
       resolved_value_type.kind_of?(JVMType)                  &&
       JVMTypeUtils.isPrimitive(JVMType(resolved_cast_type))  &&
       JVMTypeUtils.isPrimitive(JVMType(resolved_value_type))
      true
    elsif resolved_value_type.assignableFrom(resolved_cast_type)
      true
    elsif resolved_cast_type.assignableFrom(resolved_value_type)
      true
    else
      false
    end
  end

  def isNotReallyResolvedDoOnIncompatibility(resolved: ResolvedType, runnable: Runnable): boolean
    import org.mirah.jvm.mirrors.AsyncMirror
    if resolved.kind_of?(AsyncMirror) && AsyncMirror(resolved).superclass.nil?
      AsyncMirror(resolved).onIncompatibleChange runnable
      true
    elsif resolved.kind_of?(MirrorProxy)                            &&
          MirrorProxy(resolved).target.kind_of?(AsyncMirror)        &&
          AsyncMirror(MirrorProxy(resolved).target).superclass.nil?
      AsyncMirror(MirrorProxy(resolved).target).onIncompatibleChange runnable
      true
    else
      false
    end
  end

  def checkCastabilityAndUpdate(future: DelegateFuture,
                                resolved_cast_type: ResolvedType,
                                resolved_value_type: ResolvedType,
                                cast_position: Position,
                                cast_future: TypeFuture)
    if isCastable(resolved_cast_type, resolved_value_type)
      # fine, but may need to undo erroring
      future.type = cast_future
    else
      future.type = ErrorType.new([["Cannot cast #{resolved_value_type} to #{resolved_cast_type}.", cast_position]])
    end
  end

  def updateCastFuture(future: DelegateFuture,
                       resolved_cast_type: ResolvedType,
                       resolved_value_type: ResolvedType,
                       cast_position: Position,
                       cast_type: TypeFuture)
    typer = self
    if typer.isNotReallyResolvedDoOnIncompatibility(resolved_cast_type) do
        typer.checkCastabilityAndUpdate(future,
                                        resolved_cast_type,
                                        resolved_value_type,
                                        cast_position,
                                        cast_type)
      end
    elsif typer.isNotReallyResolvedDoOnIncompatibility(resolved_value_type) do
        typer.checkCastabilityAndUpdate(future,
                                        resolved_cast_type,
                                        resolved_value_type,
                                        cast_position,
                                        cast_type)
      end
    else
      typer.checkCastabilityAndUpdate(future,
                                      resolved_cast_type,
                                      resolved_value_type,
                                      cast_position,
                                      cast_type)
    end
  end

  def visitCast(cast, expression)
    value_type = infer(cast.value)
    cast_type = getTypeOf(cast, cast.type.typeref)

    future = DelegateFuture.new
    future.type = cast_type
    log = @@log
    typer = self

    value_type.onUpdate do |x, resolved_value_type|
      if cast_type.isResolved
        resolved_cast_type = cast_type.resolve
        typer.updateCastFuture(future,
                               resolved_cast_type,
                               resolved_value_type,
                               cast.position,
                               cast_type)
      end
    end
    cast_type.onUpdate do |x, resolved_cast_type|
      if value_type.isResolved
        resolved_value_type = value_type.resolve
        typer.updateCastFuture(future,
                               resolved_cast_type,
                               resolved_value_type,
                               cast.position,
                               cast_type)
      end
    end
    future
  end

  def visitColon2(colon2, expression)
    @types.getMetaType(getTypeOf(colon2, colon2.typeref))
  end

  def visitSuper(node, expression)
    method = MethodDefinition(node.findAncestor(MethodDefinition.class))
    scope = scopeOf(node)
    target = @types.getSuperClass(scope.selfType)
    parameters = inferParameterTypes node
    CallFuture.new(@types, scope, target, true, method.name.identifier, parameters, nil, node.position)
  end

  def visitZSuper(node, expression)
    method = MethodDefinition(node.findAncestor(MethodDefinition.class))
    locals = LinkedList.new
    [ method.arguments.required,
        method.arguments.optional,
        method.arguments.required2].each do |args|
      Iterable(args).each do |arg|
        farg = FormalArgument(arg)
        local = LocalAccess.new(farg.position, farg.name)
        @scopes.copyScopeFrom(farg, local)
        infer(local, true)
        locals.add(local)
      end
    end
    replacement = Super.new(node.position, locals, nil)
    infer(replaceSelf(node, replacement), expression != nil)
  end

  def visitClassDefinition(classdef, expression)
    classdef.annotations.each {|a| infer(a)}
    scope = scopeOf(classdef)
    interfaces = inferAll(scope, classdef.interfaces)
    superclass = @types.get(scope, classdef.superclass.typeref) if classdef.superclass
    name = if classdef.name
      classdef.name.identifier
    end
    type = @types.createType(scope, classdef, name, superclass, interfaces)
    addScopeWithSelfType(classdef, type)
    infer(classdef.body, false) if classdef.body
    @types.publishType(type)
    type
  end

  def visitClosureDefinition(classdef, expression)
    visitClassDefinition(classdef, expression)
  end

  def visitInterfaceDeclaration(idef, expression)
    visitClassDefinition(idef, expression)
  end

  def visitFieldAnnotationRequest(decl, expression)
    @types.getNullType()
  end
  
  def visitFieldDeclaration(decl, expression)
    inferAnnotations decl
    getFieldTypeOrDeclare(decl, decl.isStatic).declare(
                          getTypeOf(decl, decl.type.typeref),
                          decl.position)
  end

  def visitFieldAssign(field, expression)
    inferAnnotations field
    value = infer(field.value, true)
    fieldType = getFieldTypeOrDeclare(field, field.isStatic)
    if fieldType.isResolved && fieldType.resolve.isError
      fieldType.resolve
    else
      fieldType.assign(value, field.position)
    end
  end

  def visitConstantAssign(field, expression)
    newField = FieldAssign.new field.name, field.value, [
      Annotation.new(field.name.position,
        Constant.new(SimpleString.new('org.mirah.jvm.types.Modifiers')),
        [HashEntry.new(SimpleString.new('access'), SimpleString.new('PUBLIC'))])
    ]
    newField.isStatic = true
    newField.position = field.position

    replaceSelf field, newField

    infer(newField, expression != nil)
  end

  def visitFieldAccess(field, expression)
    targetType = fieldTargetType field, field.isStatic
    if targetType.nil?
      TypeFuture(ErrorType.new([["Cannot find declaring class for field.", field.position]]))
    else
      getFieldType field, targetType
    end
  end

  def visitConstant(constant, expression)

    @futures[constant] = @types.getMetaType(getTypeOf(constant, constant.typeref))

    fieldAccess = FieldAccess.new(constant.position, Identifier(constant.name.clone))
    fieldAccess.isStatic = true
    fieldAccess.position = constant.position
    variants = [constant, fieldAccess]

    # This could be Constant in static import, currently implemented by method lookup
    # Not sure should we restrict method lookup to select constants only
    # and not to infer to methods as well
    # If adding fcall without expression check - getting method duplicates in
    # macros_test.rb#test_macro_changes_body_of_class_last_element
    if expression
      fcall = FunctionalCall.new(constant.position,
                               Identifier(constant.name.clone),
                               nil, nil)
      fcall.setParent(constant.parent)
      workaroundASTBug fcall
      methodType = callMethodType fcall, Collections.emptyList
      targetType = infer(fcall.target)
      @futures[fcall] = methodType
      @futures[fcall.target] = targetType
      variants.add fcall
    end
    proxy = ProxyNode.new self, constant
    proxy.setChildren(variants, 0)

    @futures[proxy] = proxy.inferChildren(expression != nil)
  end

  def visitIf(stmt, expression)
    infer(stmt.condition, true)
    a = infer(stmt.body, expression != nil) if stmt.body
    b = infer(stmt.elseBody, expression != nil) if stmt.elseBody
    if expression && a && b
      type = AssignableTypeFuture.new(stmt.position)
      type.assign(a, stmt.body.position)
      type.assign(b, stmt.elseBody.position)
      TypeFuture(type)
    else
      a || b
    end
  end

  def visitLoop(node, expression)
    enhanceLoop(node)
    infer(node.init, false)
    infer(node.condition, true)
    infer(node.pre, false)
    infer(node.body, false)
    infer(node.post, false)
    @types.getNullType()
  end

  def visitReturn(node, expression)
    type = if node.value
      infer(node.value)
    else
      @types.getVoidType()
    end
    enclosing_node = node.findAncestor {|n| n.kind_of?(MethodDefinition) || n.kind_of?(Script)}
    if enclosing_node.kind_of? MethodDefinition
      return nil if isMethodInBlock(MethodDefinition(enclosing_node)) # return types are not supported currently for methods which act as templates
      methodType = infer enclosing_node
      returnType = MethodFuture(methodType).returnType
      assignment = returnType.assign(type, node.position)
      future = DelegateFuture.new
      future.type = returnType
      assignment.onUpdate do |x, resolved|
        if resolved.isError
          future.type = assignment
        else
          future.type = returnType
        end
      end
      TypeFuture(future)
    elsif enclosing_node.kind_of? Script
      TypeFuture(@types.getVoidType)
    end
  end

  def visitBreak(node, expression)
    @types.getNullType()
  end

  def visitNext(node, expression)
    @types.getNullType()
  end

  def visitRedo(node, expression)
    @types.getNullType()
  end

  def visitRaise(node, expression)
    # Ok, this is complicated. There's three acceptable syntaxes
    #  - raise exception_object
    #  - raise ExceptionClass, *constructor_args
    #  - raise *args_for_default_exception_class_constructor
    # We need to figure out which one is being used, and replace the
    # args with a single exception node.
    
    # TODO(ribrdb): Clean this up using ProxyNode.

    # Start by saving the old args and creating a new, empty arg list
    old_args = node.args
    node.args = NodeList.new(node.args.position)
    possibilities = ArrayList.new
    exceptions = ArrayList.new
    if old_args.size == 1
      exceptions.addAll buildNodeAndTypeForRaiseTypeOne(old_args, node)
      possibilities.add "1"
    end

    if old_args.size > 0
      exceptions.addAll buildNodeAndTypeForRaiseTypeTwo(old_args, node)
      possibilities.add "2"
    end
    exceptions.addAll buildNodeAndTypeForRaiseTypeThree(old_args, node)
      possibilities.add "3"

    log = logger()
    log.finest "possibilities #{possibilities}"
    exceptions.each do |e|
      log.finest "type possible #{e} for raise"
    end
    # Now we'll try all of these, ignoring any that cause an inference error.
    # Then we'll take the first that succeeds, in the order listed above.
    exceptionPicker = PickFirst.new(exceptions) do |type, pickedNode|
      log.finest "picking #{type} for raise"
      if node.args.size == 0
        node.args.add(Node(pickedNode))
      else
        node.args.set(0, Node(pickedNode))
      end
    end

    # We need to ensure that the chosen node is an exception.
    # So create a dummy type declared as an exception, and assign
    # the picker to it.
    exceptionType = AssignableTypeFuture.new(node.position)
    exceptionType.declare(@types.getBaseExceptionType(), node.position)
    assignment = exceptionType.assign(exceptionPicker, node.position)

    # Now we're ready to return our type. It should be UnreachableType.
    # But if none of the nodes is an exception, we need to return
    # an error.
    myType = BaseTypeFuture.new(node.position)
    unreachable = UnreachableType.new
    assignment.onUpdate do |x, resolved|
      if resolved.isError
        myType.resolved(resolved)
      else
        myType.resolved(unreachable)
      end
    end
    myType
  end

  def visitRescueClause(clause, expression)
    if clause.types_size == 0
      clause.types.add(TypeRefImpl.new(defaultExceptionTypeName,
                                       false, false, clause.position))
    end
    scope = addNestedScope clause
    name = clause.name
    if name
      scope.shadow(name.identifier)
      exceptionType = @types.getLocalType(scope, name.identifier, name.position)
      clause.types.each do |_t|
        t = TypeName(_t)
        exceptionType.assign(inferTypeName(t), t.position)
      end
    else
      inferAll(scope.parent, clause.types)
    end
    # What if body is nil?
    infer(clause.body, expression != nil)
  end

  def visitRescue(node, expression)
    # AST contains an empty else clause even if there isn't one
    # in the source. Once, the parser's compiling, we should fix it.
    hasElse = !(node.elseClause.nil? || node.elseClause.size == 0)
    bodyType = infer(node.body, expression && !hasElse) if node.body
    elseType = infer(node.elseClause, expression != nil) if hasElse
    if expression
      myType = AssignableTypeFuture.new(node.position)
      if hasElse
        myType.assign(elseType, node.elseClause.position)
      else
        myType.assign(bodyType, node.body.position)
      end
    end
    node.clauses.each do |clause|
      clauseType = infer(clause, expression != nil)
      myType.assign(clauseType, Node(clause).position) if expression
    end

    TypeFuture(myType) || @types.getNullType
  end

  def visitEnsure(node, expression)
    infer(node.ensureClause, false)
    infer(node.body, expression != nil)
  end

  def visitArray(array, expression)
    mergeUnquotes(array.values)
    component = AssignableTypeFuture.new(array.position)
    array.values.each do |v|
      node = Node(v)
      component.assign(infer(node, true), node.position)
    end
    @types.getArrayLiteralType(component, array.position)
  end

  def visitTypeArray(array, expression)
    future = DelegateFuture.new
    future.type = ErrorType.new([["Types is incompatible", array.position]])
    
    base_type = getTypeOf(array.type, TypeName(array.type).typeref)
    array_type = @types.getArrayType(base_type)
    
    mergeUnquotes(array.values)
    component = AssignableTypeFuture.new(array.position)
    array.values.each do |v|
      node = Node(v)
      component.assign(infer(node, true), node.position)
    end
    component.onUpdate do |x, resolved|
      if base_type.isResolved
        if base_type.resolve.assignableFrom(resolved) ||
           (base_type.resolve.kind_of?(org::mirah::jvm::mirrors::Number) &&
            org::mirah::jvm::mirrors::Number(base_type.resolve).isFix &&
            resolved.kind_of?(org::mirah::jvm::mirrors::Number) &&
            org::mirah::jvm::mirrors::Number(resolved).isFix)
          future.type = array_type
        else
          future.type = ErrorType.new([["#{resolved} can't be cast to #{base_type.resolve}",
                                        array.position]])
        end
      end
    end
    base_type.onUpdate do |x, resolved|
      if component.isResolved
        if resolved.assignableFrom(component.resolve) ||
           (component.resolve.kind_of?(org::mirah::jvm::mirrors::Number) &&
            org::mirah::jvm::mirrors::Number(component.resolve).isFix &&
            resolved.kind_of?(org::mirah::jvm::mirrors::Number) &&
            org::mirah::jvm::mirrors::Number(resolved).isFix)
          future.type = array_type
        else
          future.type = ErrorType.new([["#{component.resolve} can't be cast to #{resolved}",
                                        array.position]])
        end
      end
    end
    future
  end

  def visitFixnum(fixnum, expression)
    @types.getFixnumType(fixnum.value)
  end

  def visitFloat(number, expression)
    @types.getFloatType(number.value)
  end

  def visitNot(node, expression)
    type = BaseTypeFuture.new(node.position)
    null_type = @types.getNullType.resolve
    boolean_type = @types.getBooleanType.resolve
    infer(node.value).onUpdate do |x, resolved|
      if (null_type.assignableFrom(resolved) ||
          boolean_type.assignableFrom(resolved))
        type.resolved(boolean_type)
      else
        type.resolved(ErrorType.new([["#{resolved} not compatible with boolean", node.position]]))
      end
    end
    type
  end

  def visitHash(hash, expression)
    keyType = AssignableTypeFuture.new(hash.position)
    valueType = AssignableTypeFuture.new(hash.position)
    hash.each do |e|
      entry = HashEntry(e)
      keyType.assign(infer(entry.key, true), entry.key.position)
      valueType.assign(infer(entry.value, true), entry.value.position)
      infer(entry, false)
    end
    @types.getHashLiteralType(keyType, valueType, hash.position)
  end
  
  def visitHashEntry(entry, expression)
    @types.getVoidType
  end

  def visitRegex(regex, expression)
    regex.strings.each {|r| infer(r)}
    @types.getRegexType()
  end

  def visitSimpleString(string, expression)
    @types.getStringType()
  end

  def visitStringConcat(string, expression)
    string.strings.each {|s| infer(s)}
    @types.getStringType()
  end

  def visitStringEval(string, expression)
    infer(string.value)
    @types.getStringType()
  end

  def visitBoolean(bool, expression)
    @types.getBooleanType()
  end

  def visitNull(node, expression)
    @types.getNullType()
  end

  def visitCharLiteral(node, expression)
    @types.getCharType(node.value)
  end

  def visitSelf(node, expression)
    scopeOf(node).selfType
  end

  def visitTypeRefImpl(typeref, expression)
    getTypeOf(typeref, typeref)
  end

  def visitLocalDeclaration(decl, expression)
    type = getTypeOf(decl, decl.type.typeref)
    getLocalType(decl).declare(type, decl.position)
  end

  def visitLocalAssignment(local, expression)
    value = infer(local.value, true)
    getLocalType(local).assign(value, local.position)
  end

  def visitLocalAccess(local, expression)
    getLocalType(local)
  end

  def visitNodeList(body, expression)
    if body.size > 0
      i = 0
      while i < body.size # note that we re-evaluate body.size each time, as body.size may change _during_ infer(), as macros may change the AST
        res = infer(body.get(i),(i<body.size-1) ? false : expression != nil)
        i += 1
      end
      res
    else
      @types.getImplicitNilType()
    end
  end

  def visitClassAppendSelf(node, expression)
    addScopeWithSelfType node, @types.getMetaType(scopeOf(node).selfType)
    infer(node.body, false)
    @types.getNullType()
  end

  def visitNoop(noop, expression)
    @types.getVoidType()
  end

  def visitScript(script, expression)
    scope = addScopeUnder(script)
    @types.addDefaultImports(scope)
    scope.selfType = @types.getMainType(scope, script)
    infer(script.body, false)
    @types.getVoidType
  end

  def visitAnnotation(anno, expression)
    anno.values_size.times do |i|
      infer(anno.values(i).value)
    end
    getTypeOf(anno, anno.type.typeref)
  end

  def visitImport(node, expression)
    scope = scopeOf(node)
    fullName = node.fullName.identifier
    simpleName = node.simpleName.identifier
    @@log.fine "import full: #{fullName} simple: #{simpleName}"
    imported_type = if ".*".equals(simpleName)
                      # TODO support static importing a single method
                      type = @types.getMetaType(@types.get(scope, TypeName(Node(node.fullName)).typeref))
                      scope.staticImport(type)
                      type
                    else
                      scope.import(fullName, simpleName)
                      unless '*'.equals(simpleName)
                        @@log.fine "wut wut. "
                        @types.get(scope, TypeName(Node(node.fullName)).typeref)
                      end
                    end
    void_type = @types.getVoidType
    if imported_type
      DerivedFuture.new(imported_type) do |resolved|
        if resolved.isError
          resolved
        else
          void_type.resolve
        end
      end
    else
      void_type
    end
  end

  def resetScriptSelfType(node:Node)
    script = Script(node.findAncestor(Script.class))
    if script
      scope = scopeOf(script)
      if scope
        scope.selfType = @types.getMainType(scope, script)
      end
    end
  end

  def visitPackage(node, expression)
    if node.body
      scope = addScopeUnder(node)
      scope.package = node.name.identifier
      resetScriptSelfType(node)
      infer(node.body, false)
    else
      # TODO this makes things complicated. Probably package should be a property of
      # Script, and Package nodes should require a body.
      scope = scopeOf(node)
      scope.package = node.name.identifier
      resetScriptSelfType(node)
    end
    @types.getVoidType()
  end

  def visitEmptyArray(node, expression)
    size_type = infer(node.size)
    array_type = @types.getArrayType(getTypeOf(node, node.type.typeref))
    future = DelegateFuture.new
    future.type = ErrorType.new([["Array size is not a number", node.position]])
    size_type.onUpdate do |x, resolved|
      if (resolved.name.equals('byte') || resolved.name.equals('char') ||
          resolved.name.equals('short') || resolved.name.equals('int'))
        future.type = array_type
      end
    end
    future
  end

  def visitUnquote(node, expression)
    # Convert the unquote into a NodeList and replace it with the NodeList.
    # TODO(ribrdb) do these need to be cloned?
    nodes = node.nodes
    replacement = if nodes.size == 1
      Node(nodes.get(0))
    else
      NodeList.new(node.position, nodes)
    end
    replacement = replaceSelf(node, replacement)
    infer(replacement, expression != nil)
  end

  def visitUnquoteAssign(node, expression)
    replacement = Node(nil)
    object = node.unquote.object
    if object.kind_of?(FieldAccess)
      fa = FieldAccess(Object(node.name))
      replacement = FieldAssign.new(fa.position, fa.name, node.value, nil)
    else
      replacement = LocalAssignment.new(node.position, node.name, node.value)
    end
    replacement = replaceSelf(node, replacement)
    infer(replacement, expression != nil)
  end

  def visitArguments(args, expression)
    mergeUnquotedArgs(args)

    # Then do normal type inference.
    inferAll(args)
    @types.getVoidType()
  end

  def mergeUnquotedArgs(args:Arguments): void
    it = args.required.listIterator
    mergeArgs(args,
              it,
              it,
              args.optional.listIterator(args.optional_size),
              args.required2.listIterator(args.required2_size))
    it = args.optional.listIterator
    mergeArgs(args,
              it,
              args.required.listIterator(args.required_size),
              it,
              args.required2.listIterator(args.required2_size))
    it = args.required.listIterator
    mergeArgs(args,
              it,
              args.required.listIterator(args.required_size),
              args.optional.listIterator(args.optional_size),
              it)
  end

  def mergeArgs(args:Arguments, it:ListIterator, req:ListIterator, opt:ListIterator, req2:ListIterator):void
    #it.each do |arg|
    while it.hasNext
      arg = FormalArgument(it.next)
      name = arg.name
      next unless name.kind_of?(Unquote)
      next if arg.type # If the arg has a type then the unquote must only be an identifier.

      unquote = Unquote(name)
      new_args = unquote.arguments
      next unless new_args

      it.remove
      import static org.mirah.util.Comparisons.*
      if areSame(it, req2) && new_args.optional.size == 0 && new_args.rest.nil? && new_args.required2.size == 0
        mergeIterators(new_args.required.listIterator, req2)
      else
        mergeIterators(new_args.required.listIterator, req)
        mergeIterators(new_args.optional.listIterator, opt)
        mergeIterators(new_args.required2.listIterator, req2)
      end
      if new_args.rest
        raise IllegalArgumentException, "Only one rest argument allowed." if args.rest
        rest = new_args.rest
        new_args.rest = nil
        args.rest = rest
      end
      if new_args.block
        raise IllegalArgumentException, "Only one block argument allowed" if args.block
        block = new_args.block
        new_args.block = nil
        args.block = block
      end
    end
  end

  def mergeIterators(source:ListIterator, dest:ListIterator):void
    #source.each do |a|
    while source.hasNext
      a = source.next
      source.remove
      dest.add(a)
    end
  end

  def mergeUnquotes(list:NodeList):void
    it = list.listIterator
    #it.each do |item|
    while it.hasNext
      item = it.next
      if item.kind_of?(Unquote)
        it.remove
        Unquote(item).nodes.each do |node|
          it.add(node)
        end
      end
    end
  end

  def visitRequiredArgument(arg, expression)
    getArgumentType arg
  end

  def visitOptionalArgument(arg, expression)
    type = getArgumentType arg
    type.assign(infer(arg.value), arg.value.position)
    type
  end

  def visitRestArgument(arg, expression)
    if arg.type
      getLocalType(arg).declare(
        @types.getArrayType(getTypeOf(arg, arg.type.typeref)),
        arg.type.position)
    else
      getLocalType(arg)
    end
  end





  def addScopeForMethod(mdef: Block): void
    scope = addScopeWithSelfType(mdef, selfTypeOf(mdef))
    addScopeUnder(mdef)
  end

  def selfTypeOf(mdef: Block): TypeFuture
    selfType = scopeOf(mdef).selfType
    if mdef.kind_of?(StaticMethodDefinition)
      selfType = @types.getMetaType(selfType)
    end
    selfType
  end


  # cp of method def
  def inferClosureBlock(block:Block, method_type: MethodType)
    @@log.entering("Typer", "inferClosureBlock", "inferClosureBlock(#{block})")
    # TODO optional arguments

    # shadowing arguments
    clsScope = ClosureScope(@scopes.getIntroducedScope(block))
    [block.arguments.required,
     block.arguments.optional,
     block.arguments.required2].each do |args|
      Iterable(args).each do |arg|
        farg = FormalArgument(arg)
        argName = farg.name.identifier
        clsScope.shadow(argName) unless clsScope.shadowed?(argName)
      end
    end
    if block.arguments.rest
      argName = block.arguments.rest.name.identifier
      clsScope.shadow(argName) unless clsScope.shadowed?(argName)
    end
    if block.arguments.block
      argName = block.arguments.block.name.identifier
      clsScope.shadow(argName) unless clsScope.shadowed?(argName)
    end

    #inferAll(block.annotations) # blocks have no annotations
    # block args can be nil...
    parameters = if block.arguments
        infer(block.arguments)
        inferAll(block.arguments)
      else
        []
      end

    if parameters.size != method_type.parameterTypes.size
      position = block.arguments.position if block.arguments
      position ||= block.position
      return @futures[block] = ErrorType.new([["Wrong number of methods for block implementing #{method_type}", position]])

    end
    # parameters.zip(method_type.parameterTypes).each do |...
    i = 0
    parameters.each do |param_type: AssignableTypeFuture|
      if !param_type.hasDeclaration
        resolved = ResolvedType(method_type.parameterTypes.get(i))
        typeName = resolved.name
        isArray = false
        if typeName.endsWith('[]')
          typeName = typeName.substring(0, typeName.length - 2)
          isArray = true
        end
        future = @types.get(
          scopeOf(block),
          TypeRefImpl.new(typeName, isArray))
        param_type.declare(
                future,
                block.arguments.position)
      end
      i += 1
    end

    selfType = selfTypeOf(block)

  ret_future = AssignableTypeFuture.new(block.position)
  rtype = BaseTypeFuture.new(block.position)
  rtype.resolved((method_type.returnType))
  ret_future.declare(rtype, block.position)


  type = MethodFuture.new(
    method_type.name,
    method_type.parameterTypes,
    ret_future,
    method_type.isVararg,
    block.position)

    @futures[block] = type
   # TODO default arg versions, what do default args even mean for blocks?
   # maybe null -> default?
   # declareOptionalMethods(selfType,
   #                        block,
   #                        parameters,
   #                        type.returnType)

    # TODO deal with overridden methods?
    # TODO throws
    # mdef.exceptions.each {|e| type.throws(@types.get(TypeName(e).typeref))}
    if isVoid type
      infer(block.body, false)
      type.returnType.assign(@types.getVoidType, block.position)
    else
      type.returnType.assign(infer(block.body), block.body.position)
    end
    type
  end


  def visitMethodDefinition(mdef, expression)
    @@log.entering("Typer", "visitMethodDefinition", mdef)
    # TODO optional arguments


    if !isMethodInBlock(mdef)
      addScopeForMethod(mdef)
      @@log.finest "Normal method #{mdef}."
      inferAll(mdef.annotations)
      infer(mdef.arguments)
      parameters = inferAll(mdef.arguments)
  
      if mdef.type
        returnType = getTypeOf(mdef, mdef.type.typeref)
      end
  
      selfType = selfTypeOf(mdef)
      type = @types.getMethodDefType(selfType,
                                     mdef.name.identifier,
                                     parameters,
                                     returnType,
                                     mdef.name.position,
                                     (mdef.arguments.rest &&
                                      mdef.arguments.required2.size==0 &&
                                      mdef.arguments.block.nil?))
      @futures[mdef] = type
      declareOptionalMethods(selfType,
                             mdef,
                             parameters,
                             type.returnType)
  
      # TODO deal with overridden methods?
      # TODO throws
      # mdef.exceptions.each {|e| type.throws(@types.get(TypeName(e).typeref))}
      if isVoid type
        infer(mdef.body, false)
        type.returnType.assign(@types.getVoidType, mdef.position)
      else
        type.returnType.assign(infer(mdef.body), mdef.body.position)
      end
      type
    else  # We are a method defined in a block. We are just a template for a method in a ClosureDefinition
      block = Block(mdef.parent.parent)
      @@log.finest "Method #{mdef} is member of #{block}"
      scope_around_block = scopeOf(block)
      scope              = addScopeUnder(mdef)
      scope.selfType     = scope_around_block.selfType
      scope.parent       = scope_around_block # We may want to access variables available in the scope outside of the block.
      infer(mdef.body, false)                 # We want to determine which free variables are referenced in the MethodDefinition.
      nil                                     # But we are actually not interested in the return type of the MethodDefintion, as this special MethodDefinition will be cloned into an AST of an anonymous class.
    end
  end
  
  def declareOptionalMethods(target:TypeFuture, mdef:MethodDefinition, argTypes:List, type:TypeFuture):void
    if mdef.arguments.optional_size > 0
      args = ArrayList.new(argTypes)
      first_optional_arg = mdef.arguments.required_size
      last_optional_arg = first_optional_arg + mdef.arguments.optional_size - 1
      last_optional_arg.downto(first_optional_arg) do |i|
        args.remove(i)
        @types.getMethodDefType(target, mdef.name.identifier, args, type, mdef.name.position,
                                (mdef.arguments.rest && mdef.arguments.required2.size==0 &&
                                 mdef.arguments.block.nil?))
      end
    end
  end

  def visitStaticMethodDefinition(mdef, expression)
    visitMethodDefinition(mdef, expression)
  end

  def visitConstructorDefinition(mdef, expression)
    visitMethodDefinition(mdef, expression)
  end

  def visitImplicitNil(node, expression)
    @types.getImplicitNilType()
  end

  def visitImplicitSelf(node, expression)
    scopeOf(node).selfType
  end

  # TODO is a constructor special?

  def visitBlock(block, expression)
    expandUnquotedBlockArgs(block)
    if block.arguments
      mergeUnquotedArgs(block.arguments)
    end

    closures = @closures
    typer = self
    typer.logger.fine "at block future registration for #{block}"
    BlockFuture.new(block) do |block_future, resolvedType|
      typer.logger.fine "in block future for #{block}: resolvedType=#{resolvedType}\n  #{typer.sourceContent block}"
      closures.add_todo block, resolvedType
    end
  end

  def expandUnquotedBlockArgs(block: Block): void
    expandPipedUnquotedBlockArgs(block)
    expandUnpipedUnquotedBlockArgs(block)
  end

  # expand cases like
  # x = block.arguments
  # quote { y { |`x`| `x.name` +  1 } }
  def expandPipedUnquotedBlockArgs(block: Block): void
    return if block.arguments.nil?
    return if block.arguments.required_size() == 0
    return unless block.arguments.required(0).name.kind_of? Unquote
    unquote_arg = Unquote(block.arguments.required(0).name)
    return unless unquote_arg.object.kind_of?(Arguments)

    @@log.finest "Block: expanding unquoted arguments with pipes"
    unquoted_args = Arguments(unquote_arg.object)
    block.arguments = unquoted_args
    unquoted_args.setParent block
  end

  def expandUnpipedUnquotedBlockArgs(block: Block): void
    return unless block.arguments.nil?
    return if block.body.nil? || block.body.size == 0
    return unless block.body.get(0).kind_of?(Unquote)
    unquoted_first_element = Unquote(block.body.get(0))
    return unless unquoted_first_element.object.kind_of?(Arguments)

    @@log.finest "Block: expanding unquoted arguments with no pipes"
    unquoted_args = Arguments(unquoted_first_element.object)
    block.arguments = unquoted_args
    unquoted_args.setParent block
    block.body.removeChild block.body.get(0)
  end
  
  def visitSyntheticLambdaDefinition(node, expression)
    supertype = infer(node.supertype)
    block     = BlockFuture(infer(node.block))
    SyntheticLambdaFuture.new(supertype,block,node.position)
  end

  # Returns true if any MethodDefinitions were found.
  def contains_methods(block: Block): boolean
    block.body_size.times do |i|
      node = block.body(i)
      return true if node.kind_of?(MethodDefinition)
    end
    return false
  end

  def visitBindingReference(ref, expression)
    binding = scopeOf(ref).binding_type
    future = BaseTypeFuture.new
    future.resolved(binding)
    future
  end

  def visitMacroDefinition(defn, expression)
    @macros.buildExtension(defn)
    #defn.parent.removeChild(defn)
    @types.getVoidType()
  end

  # Look for special blocks in the loop body and move them into the loop node.
  def enhanceLoop(node:Loop):void
    it = node.body.listIterator
    while it.hasNext
      child = it.next
      if child.kind_of?(FunctionalCall)
        call = FunctionalCall(child)
        name = call.name.identifier rescue nil
        if name.nil? || call.parameters_size() != 0 || call.block.nil?
          return
        end
        target_list = if name.equals("init")
          node.init
        elsif name.equals("pre")
          node.pre
        elsif name.equals("post")
          node.post
        else
          NodeList(nil)
        end
        if target_list
          it.remove
          target_list.add(call.block.body)
        else
          return
          nil
        end
      else
        return
        nil
      end
    end
  end

  def buildNodeAndTypeForRaiseTypeOne(old_args: NodeList, node: Node)
    exception_node = Node(old_args.clone)
    exception_node.setParent(node)
    new_type = BaseTypeFuture.new(exception_node.position)
    error = ErrorType.new([["Not an expression", exception_node.position]])
    infer(exception_node).onUpdate do |x, resolvedType|
      # We need to make sure they passed an object, not just a class name
      if resolvedType.isMeta
        new_type.resolved(error)
      else
        new_type.resolved(resolvedType)
      end
    end
    exception_node.setParent(nil)
    # Now we need to make sure the object is an exception, otherwise we
    # need to use a different syntax.
    exceptionType = AssignableTypeFuture.new(exception_node.position)
    exceptionType.declare(@types.getBaseExceptionType(), node.position)
    assignment = exceptionType.assign(new_type, node.position)
    [assignment, exception_node]
  end

  def buildNodeAndTypeForRaiseTypeTwo(old_args: NodeList, node: Node)
    targetNode = Node(Node(old_args.get(0)).clone)
    params = ArrayList.new
    1.upto(old_args.size - 1) {|i| params.add(Node(old_args.get(i)).clone)}
    call = Call.new(node.position, targetNode, SimpleString.new(node.position, 'new'), params, nil)
    wrapper = NodeList.new([call])
    @scopes.copyScopeFrom(node, wrapper)
    [infer(wrapper), wrapper]
  end

  def buildNodeAndTypeForRaiseTypeThree(old_args: NodeList, node: Node)
    targetNode = Constant.new(node.position,
                              SimpleString.new(node.position,
                                defaultExceptionTypeName))
    params = ArrayList.new
    old_args.each {|a| params.add(Node(a).clone)}
    call = Call.new(node.position, targetNode, SimpleString.new(node.position, 'new'), params, nil)
    wrapper = NodeList.new([call])
    @scopes.copyScopeFrom(node, wrapper)
    [infer(wrapper), wrapper]
  end

  def defaultExceptionTypeName
    @types.getDefaultExceptionType().resolve.name
  end

  def selfTypeOf(mdef: MethodDefinition): TypeFuture
    selfType = scopeOf(mdef).selfType
    if mdef.kind_of?(StaticMethodDefinition)
      selfType = @types.getMetaType(selfType)
    end
    selfType
  end

  def isVoid type: MethodFuture
    type.returnType.isResolved && @types.getVoidType().resolve.equals(type.returnType.resolve)
  end

  def getLocalType(local: Named)
    getLocalType(local, local.name.identifier)
  end

  def getLocalType(arg: Node, identifier: String): AssignableTypeFuture
    @types.getLocalType(scopeOf(arg), identifier, arg.position)
  end

  def getArgumentType(arg: FormalArgument)
    type = getLocalType arg
    if arg.type
      type.declare(
        getTypeOf(arg, arg.type.typeref),
        arg.type.position)
    end
    type
  end

  def getTypeOf(node: Node, typeref: TypeRef)
    @types.get(scopeOf(node), typeref)
  end

  def inferCallTarget target: Node, scope: Scope
    targetType = infer(target)
    targetType = @types.getMetaType(targetType) if scope.context.kind_of?(ClassDefinition)
    targetType
  end

  def addScopeForMethod(mdef: MethodDefinition): void
    scope = addScopeWithSelfType(mdef, selfTypeOf(mdef))
    addScopeUnder(mdef)
  end
  
  def isMethodInBlock(mdef: MethodDefinition): boolean
    mdef.parent.kind_of?(NodeList) && mdef.parent.parent.kind_of?(Block)
  end

  def addScopeWithSelfType(node: Node, selfType: TypeFuture)
    scope = addScopeUnder(node)
    scope.selfType = selfType
    scope
  end

  def scopeOf(node: Node)
    @scopes.getScope node
  end

  def addScopeUnder(node: Node)
    @scopes.addScope node
  end

  def addNestedScope node: Node
    scope = addScopeUnder(node)
    scope.parent = scopeOf(node)
    scope
  end

  def callMethodType call: CallSite, parameters: List
    scope = scopeOf(call)
    targetType = inferCallTarget call.target, scope
    methodType = CallFuture.new(@types,
                                scope,
                                targetType,
                                false,
                                parameters,
                                call)
  end

  def inferAnnotations annotated: Annotated
    annotated.annotations.each {|a| infer(a)}
  end

  def inferParameterTypes call: CallSite
    mergeUnquotes(call.parameters)
    parameters = inferAll(call.parameters)
    parameters.add(infer(call.block, true)) if call.block
    parameters
  end

  # FIXME: Super should be a CallSite
  def inferParameterTypes call: Super
    mergeUnquotes(call.parameters)
    parameters = inferAll(call.parameters)
    parameters.add(infer(call.block, true)) if call.block
    parameters
  end

    # FIXME: fieldX nodes should have isStatic as an interface method
  def fieldTargetType field: Named, isStatic: boolean
    targetType = scopeOf(field).selfType
    return nil unless targetType
    if isStatic
      @types.getMetaType(targetType)
    else
      targetType
    end
  end

  def getFieldType(field: Named, isStatic: boolean)
    getFieldType(field, fieldTargetType(field, isStatic))
  end

  def getFieldType field: Named, targetType: TypeFuture
    @types.getFieldType(targetType,
                        field.name.identifier,
                        field.position)
  end

  def getFieldTypeOrDeclare(field: Named, isStatic: boolean)
    getFieldTypeOrDeclare(field, fieldTargetType(field, isStatic))
  end

  def getFieldTypeOrDeclare field: Named, targetType: TypeFuture
    @types.getFieldTypeOrDeclare(targetType,
                        field.name.identifier,
                        field.position)
  end

  def expandMacro node: Node, inline_type: ResolvedType
    logger.fine("Expanding macro #{node}")
    InlineCode(inline_type).expand(node, self)
  end

  def replaceAndInfer(future: DelegateFuture,
    current_node: Node,
    replacement: Node,
    expression: boolean)
    node = replaceSelf(current_node, replacement)
    future.type = infer(node, expression)
    node
  end

  def replaceSelf me: Node, replacement: Node
    me.parent.replaceChild(me, replacement)
  end


  def isMacro resolvedType: ResolvedType
    resolvedType.kind_of?(InlineCode)
  end

  def expandAndReplaceMacro future: DelegateFuture, current_node: Node, fcall: Node, picked_type: ResolvedType, expression: boolean
    if current_node.parent
      replaceAndInfer(
                     future,
                     current_node,
                     expandMacro(fcall, picked_type),
                     expression)
    end
  end

  # FIXME: there's a bug in the AST that doesn't set the
  # calls target correctly
  def workaroundASTBug(call: CallSite)
    call.target.setParent(call)
  end

  def sourceContent node: Node
    return "<source non-existent>" unless node
    sourceContent node.position
  end
  def sourceContent pos: Position
    return "<source non-existent>" if pos.nil? || pos.source.nil?
    return "<source start/end negative start:#{pos.startChar} end:#{pos.endChar}>" if  pos.startChar < 0 || pos.endChar < 0
    return "<source start after end start:#{pos.startChar} end:#{pos.endChar}>" if  pos.startChar > pos.endChar

    begin
      pos.source.substring(pos.startChar, pos.endChar)
    rescue => e
      "<error getting source: #{e}  start:#{pos.startChar} end:#{pos.endChar}>"
    end
  end
end
