// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dev_compiler.src.codegen.side_effect_analysis;

import 'package:analyzer/src/generated/ast.dart';
import 'package:analyzer/src/generated/constant.dart';
import 'package:analyzer/src/generated/element.dart';
import 'package:analyzer/src/generated/error.dart' show ErrorReporter;
import 'package:analyzer/src/generated/engine.dart' show RecordingErrorListener;
import 'package:analyzer/src/generated/resolver.dart' show TypeProvider;

/// True is the expression can be evaluated multiple times without causing
/// code execution. This is true for final fields. This can be true for local
/// variables, if:
/// * they are not assigned within the [context].
/// * they are not assigned in a function closure anywhere.
/// True is the expression can be evaluated multiple times without causing
/// code execution. This is true for final fields. This can be true for local
/// variables, if:
///
/// * they are not assigned within the [context] scope.
/// * they are not assigned in a function closure anywhere.
///
/// This method is used to avoid creating temporaries in cases where we know
/// we can safely re-evaluate [node] multiple times in [context]. This lets
/// us generate prettier code.
///
/// This method is conservative: it should never return `true` unless it is
/// certain the [node] is stateless, because generated code may rely on the
/// correctness of a `true` value. However it may return `false` for things
/// that are in fact, stateless.
bool isStateless(Expression node, [AstNode context]) {
  // `this` and `super` cannot be reassigned.
  if (node is ThisExpression || node is SuperExpression) return true;
  if (node is SimpleIdentifier) {
    var e = node.staticElement;
    if (e is PropertyAccessorElement) e = e.variable;
    if (e is VariableElement && !e.isSynthetic) {
      if (e.isFinal) return true;
      if (e is LocalVariableElement || e is ParameterElement) {
        // make sure the local isn't mutated in the context.
        return !_isPotentiallyMutated(e, context);
      }
    }
  }
  return false;
}

/// Returns true if the local variable is potentially mutated within [context].
/// This accounts for closures that may have been created outside of [context].
bool _isPotentiallyMutated(VariableElement e, [AstNode context]) {
  if (e.isPotentiallyMutatedInClosure) return true;
  if (e.isPotentiallyMutatedInScope) {
    // Need to visit the context looking for assignment to this local.
    if (context != null) {
      var visitor = new _AssignmentFinder(e);
      context.accept(visitor);
      return visitor._potentiallyMutated;
    }
    return true;
  }
  return false;
}

/// Adapted from VariableResolverVisitor. Finds an assignment to a given
/// local variable.
class _AssignmentFinder extends RecursiveAstVisitor {
  final VariableElement _variable;
  bool _potentiallyMutated = false;

  _AssignmentFinder(this._variable);

  @override
  visitSimpleIdentifier(SimpleIdentifier node) {
    // Ignore if qualified.
    AstNode parent = node.parent;
    if (parent is PrefixedIdentifier &&
        identical(parent.identifier, node)) return;
    if (parent is PropertyAccess &&
        identical(parent.propertyName, node)) return;
    if (parent is MethodInvocation &&
        identical(parent.methodName, node)) return;
    if (parent is ConstructorName) return;
    if (parent is Label) return;

    if (node.inSetterContext() && node.staticElement == _variable) {
      _potentiallyMutated = true;
    }
  }
}

class ConstFieldVisitor {
  final ConstantVisitor _constantVisitor;

  ConstFieldVisitor(TypeProvider types, CompilationUnit unit)
      : _constantVisitor = new ConstantVisitor.con1(types,
          new ErrorReporter(new RecordingErrorListener(), unit.element.source));

  // TODO(jmesserly): this is used to determine if the field initialization is
  // side effect free. We should make the check more general, as things like
  // list/map literals/regexp are also side effect free and fairly common
  // to use as field initializers.
  bool isFieldInitConstant(VariableDeclaration field) =>
      field.initializer == null || computeConstant(field) != null;

  DartObjectImpl computeConstant(VariableDeclaration field) {
    // If the constant is already computed by ConstantEvaluator, just return it.
    VariableElementImpl element = field.element;
    var result = element.evaluationResult;
    if (result != null) return result.value;

    // ConstantEvaluator will not compute constants for non-const fields,
    // so run ConstantVisitor for those to figure out if the initializer is
    // actually a constant (and therefore side effect free to evaluate).
    assert(!field.isConst);

    var initializer = field.initializer;
    if (initializer == null) return null;
    return initializer.accept(_constantVisitor);
  }
}
