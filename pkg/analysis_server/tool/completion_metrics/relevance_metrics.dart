// Copyright (c) 2020, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:math' as math;

import 'package:_fe_analyzer_shared/src/base/syntactic_entity.dart';
import 'package:analysis_server/src/protocol_server.dart'
    show convertElementToElementKind, ElementKind;
import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart'
    show
        ClassElement,
        Element,
        ExecutableElement,
        ExtensionElement,
        LibraryElement,
        LocalVariableElement,
        ParameterElement;
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/dart/element/type_system.dart';
import 'package:analyzer/diagnostic/diagnostic.dart';
import 'package:analyzer/file_system/physical_file_system.dart';
import 'package:analyzer/src/dart/element/inheritance_manager3.dart';
import 'package:analyzer/src/generated/engine.dart';

Future<void> main(List<String> args) async {
  var out = io.stdout;
  if (args.isEmpty) {
    out.writeln('Usage: a single absolute file path to analyze.');
    await out.flush();
    io.exit(1);
  }

  var rootPath = args[0];
  out.writeln('Analyzing root: \"$rootPath\"');
  if (!io.Directory(rootPath).existsSync()) {
    out.writeln('\tError: No such directory exists on this machine.\n');
    return;
  }

  var computer = RelevanceMetricsComputer();
  var stopwatch = Stopwatch();
  stopwatch.start();
  await computer.compute(rootPath);
  stopwatch.stop();
  var duration = Duration(milliseconds: stopwatch.elapsedMilliseconds);
  out.writeln('  Metrics computed in $duration');
  computer.writeMetrics(out);
  await out.flush();
  io.exit(0);
}

/// An object that records the data used to compute the metrics.
class RelevanceData {
  /// A number identifying the version of this code that produced a given JSON
  /// encoded file. The number should be incremented whenever the shape of the
  /// JSON file is changed.
  static const String currentVersion = '1';

  /// A table mapping match distances to counts by kind of distance.
  Map<String, Map<String, int>> byDistance = {};

  /// A table mapping element kinds to counts by context.
  Map<String, Map<String, int>> byElementKind = {};

  /// A table mapping AST node classes to counts by context.
  Map<String, Map<String, int>> byNodeClass = {};

  /// A table mapping token types to counts by context.
  Map<String, Map<String, int>> byTokenType = {};

  /// A table mapping match types to counts by kind of type match.
  Map<String, Map<String, int>> byTypeMatch = {};

  /// A table mapping distances from an identifier to the nearest previous token
  /// with the same lexeme to the number of times that distance was found.
  Map<int, int> tokenDistances = {};

  /// Initialize a newly created set of relevance data to be empty.
  RelevanceData();

  /// Initialize a newly created set of relevance data to reflect the data in
  /// the given JSON encoded [content].
  RelevanceData.fromJson(String content) {
    _initializeFromJson(content);
  }

  /// Add the data from the given relevance [data] to this set of data.
  void addDataFrom(RelevanceData data) {
    _addToMap(byDistance, data.byDistance);
    _addToMap(byElementKind, data.byElementKind);
    _addToMap(byNodeClass, data.byNodeClass);
    _addToMap(byTokenType, data.byTokenType);
    _addToMap(byTypeMatch, data.byTypeMatch);
  }

  /// Record that a reference to an element was found and that the distance
  /// between that reference and the declaration site is the given [distance].
  /// The [descriptor] is used to describe the kind of distance being measured.
  void recordDistance(String descriptor, int distance) {
    var contextMap = byDistance.putIfAbsent(descriptor, () => {});
    var key = distance.toString();
    contextMap[key] = (contextMap[key] ?? 0) + 1;
  }

  /// Record that an element of the given [kind] was found in the given
  /// [context].
  void recordElementKind(String context, ElementKind kind) {
    var contextMap = byElementKind.putIfAbsent(context, () => {});
    var key = kind.name;
    contextMap[key] = (contextMap[key] ?? 0) + 1;
  }

  /// Record that an element of the given [node] was found in the given
  /// [context].
  void recordNodeClass(String context, AstNode node) {
    var contextMap = byNodeClass.putIfAbsent(context, () => {});
    var className = node.runtimeType.toString();
    if (className.endsWith('Impl')) {
      className = className.substring(0, className.length - 4);
    }
    contextMap[className] = (contextMap[className] ?? 0) + 1;
  }

  /// Record information about the distance between recurring tokens.
  void recordTokenStream(int distance) {
    tokenDistances[distance] = (tokenDistances[distance] ?? 0) + 1;
  }

  /// Record that a token of the given [type] was found in the given [context].
  void recordTokenType(String context, TokenType type) {
    var contextMap = byTokenType.putIfAbsent(context, () => {});
    var key = type.name;
    contextMap[key] = (contextMap[key] ?? 0) + 1;
  }

  /// Record whether the given [kind] or type match applied to a given argument
  /// (that is, whether [matches] is `true`).
  void recordTypeMatch(String kind, String matchKind) {
    var contextMap = byTypeMatch.putIfAbsent(kind, () => {});
    contextMap[matchKind] = (contextMap[matchKind] ?? 0) + 1;
  }

  /// Return a JSON encoded string representing the data that was collected.
  String toJson() {
    return json.encode({
      'version': currentVersion,
      'byDistance': byDistance,
      'byElementKind': byElementKind,
      'byNodeClass': byNodeClass,
      'byTokenType': byTokenType,
      'byTypeMatch': byTypeMatch,
    });
  }

  /// Add the data in the [source] map to the [target] map.
  void _addToMap(Map<String, Map<String, int>> target,
      Map<String, Map<String, int>> source) {
    for (var outerEntry in source.entries) {
      var innerTarget = target.putIfAbsent(outerEntry.key, () => {});
      for (var innerEntry in outerEntry.value.entries) {
        var innerKey = innerEntry.key;
        innerTarget[innerKey] = (innerTarget[innerKey] ?? 0) + innerEntry.value;
      }
    }
  }

  Map<String, dynamic> _convert(dynamic value) {
    if (value is Map<String, dynamic>) {
      return value;
    }
    throw FormatException('Expected a JSON map.', value);
  }

  /// Decode the content of the [source] map into the [target] map, using the
  /// [keyMapper] to map the inner keys from a string to a [T].
  void _decodeMap(
      Map<String, Map<String, int>> target, Map<String, dynamic> source) {
    var outerMap = _convert(source);
    for (var outerEntry in outerMap.entries) {
      var outerKey = outerEntry.key;
      var innerMap = _convert(outerEntry.value);
      for (var innerEntry in innerMap.entries) {
        var innerKey = innerEntry.key;
        var count = innerEntry.value as int;
        target.putIfAbsent(outerKey, () => {})[innerKey] = count;
      }
    }
  }

  /// Initialize the state of this object from the given JSON encoded [content].
  void _initializeFromJson(String content) {
    var contentObject = _convert(json.decode(content));
    var version = contentObject['version'].toString();
    if (version != currentVersion) {
      throw StateError(
          'Invalid version: expected $currentVersion, found $version');
    }
    _decodeMap(byDistance, contentObject['byDistance']);
    _decodeMap(byElementKind, contentObject['byElementKind']);
    _decodeMap(byNodeClass, contentObject['byNodeClass']);
    _decodeMap(byTokenType, contentObject['byTokenType']);
    _decodeMap(byTypeMatch, contentObject['byTypeMatch']);
  }
}

/// An object that visits a compilation unit in order to record the data used to
/// compute the metrics.
class RelevanceDataCollector extends RecursiveAstVisitor<void> {
  static const List<Keyword> declarationKeywords = [
    Keyword.MIXIN,
    Keyword.TYPEDEF
  ];

  static const List<Keyword> directiveKeywords = [
    Keyword.EXPORT,
    Keyword.IMPORT,
    Keyword.LIBRARY,
    Keyword.PART
  ];

  static const List<Keyword> exportKeywords = [
    Keyword.AS,
    Keyword.HIDE,
    Keyword.SHOW
  ];

  static const List<Keyword> expressionKeywords = [
    Keyword.AWAIT,
    Keyword.SUPER
  ];

  static const List<Keyword> functionBodyKeywords = [
    Keyword.ASYNC,
    Keyword.SYNC
  ];

  static const List<Keyword> importKeywords = [
    Keyword.AS,
    Keyword.HIDE,
    Keyword.SHOW
  ];

  static const List<Keyword> memberKeywords = [
    Keyword.FACTORY,
    Keyword.GET,
    Keyword.OPERATOR,
    Keyword.SET,
    Keyword.STATIC
  ];

  static const List<Keyword> noKeywords = [];

  static const List<Keyword> statementKeywords = [Keyword.AWAIT, Keyword.YIELD];

  /// The relevance data being collected.
  final RelevanceData data;

  InheritanceManager3 inheritanceManager = InheritanceManager3();

  /// The library containing the compilation unit being visited.
  LibraryElement enclosingLibrary;

  /// The type system associated with the current compilation unit.
  TypeSystem typeSystem;

  /// Initialize a newly created collector to add data points to the given
  /// [data].
  RelevanceDataCollector(this.data);

  @override
  void visitAdjacentStrings(AdjacentStrings node) {
    // There are no completions.
    super.visitAdjacentStrings(node);
  }

  @override
  void visitAnnotation(Annotation node) {
    _recordDataForNode('Annotation (name)', node.name);
    super.visitAnnotation(node);
  }

  @override
  void visitArgumentList(ArgumentList node) {
    for (var argument in node.arguments) {
      if (argument is NamedExpression) {
        _recordDataForNode('ArgumentList (named)', argument.expression,
            allowedKeywords: expressionKeywords);
        _recordTypeMatch(argument.expression);
      } else {
        _recordDataForNode('ArgumentList (unnamed)', argument,
            allowedKeywords: expressionKeywords);
        _recordTypeMatch(argument);
      }
    }
    super.visitArgumentList(node);
  }

  @override
  void visitAsExpression(AsExpression node) {
    _recordDataForNode('AsExpression (type)', node.type);
    super.visitAsExpression(node);
  }

  @override
  void visitAssertInitializer(AssertInitializer node) {
    _recordDataForNode('AssertInitializer (condition)', node.condition,
        allowedKeywords: expressionKeywords);
    _recordDataForNode('AssertInitializer (message)', node.message,
        allowedKeywords: expressionKeywords);
    super.visitAssertInitializer(node);
  }

  @override
  void visitAssertStatement(AssertStatement node) {
    _recordDataForNode('AssertStatement (condition)', node.condition,
        allowedKeywords: expressionKeywords);
    _recordDataForNode('AssertStatement (message)', node.message,
        allowedKeywords: expressionKeywords);
    super.visitAssertStatement(node);
  }

  @override
  void visitAssignmentExpression(AssignmentExpression node) {
    _recordDataForNode('AssignmentExpression (rhs)', node.rightHandSide,
        allowedKeywords: expressionKeywords);
    var operatorType = node.operator.type;
    if (operatorType != TokenType.EQ &&
        operatorType != TokenType.QUESTION_QUESTION_EQ) {
      _recordTypeMatch(node.rightHandSide);
    }
    super.visitAssignmentExpression(node);
  }

  @override
  void visitAwaitExpression(AwaitExpression node) {
    _recordDataForNode('AwaitExpression (expression)', node.expression,
        allowedKeywords: expressionKeywords);
    super.visitAwaitExpression(node);
  }

  @override
  void visitBinaryExpression(BinaryExpression node) {
    var operator = node.operator.lexeme;
    _recordDataForNode('BinaryExpression ($operator)', node.rightOperand,
        allowedKeywords: expressionKeywords);
    if (node.operator.isUserDefinableOperator) {
      _recordTypeMatch(node.rightOperand);
    }
    super.visitBinaryExpression(node);
  }

  @override
  void visitBlock(Block node) {
    for (var statement in node.statements) {
      // Function declaration statements that have no return type begin with an
      // identifier but don't have an element kind associated with the
      // identifier.
      _recordDataForNode('Block (statement)', statement,
          allowedKeywords: statementKeywords);
    }
    super.visitBlock(node);
  }

  @override
  void visitBlockFunctionBody(BlockFunctionBody node) {
    _recordTokenType('BlockFunctionBody (start)', node,
        allowedKeywords: functionBodyKeywords);
    super.visitBlockFunctionBody(node);
  }

  @override
  void visitBooleanLiteral(BooleanLiteral node) {
    _recordTokenType('BooleanLiteral (start)', node);
    super.visitBooleanLiteral(node);
  }

  @override
  void visitBreakStatement(BreakStatement node) {
    // The token following the `break` (if there is one) is always a label.
    super.visitBreakStatement(node);
  }

  @override
  void visitCascadeExpression(CascadeExpression node) {
    for (var cascade in node.cascadeSections) {
      _recordDataForNode('CascadeExpression (section)', cascade);
    }
    super.visitCascadeExpression(node);
  }

  @override
  void visitCatchClause(CatchClause node) {
    _recordDataForNode('CatchClause (on)', node.exceptionType);
    super.visitCatchClause(node);
  }

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    var context = 'name';
    if (node.extendsClause != null) {
      _recordTokenType('ClassDeclaration ($context)', node.extendsClause,
          allowedKeywords: [Keyword.EXTENDS]);
      context = 'extends';
    }
    if (node.withClause != null) {
      _recordTokenType('ClassDeclaration ($context)', node.withClause);
      context = 'with';
    }
    _recordTokenType('ClassDeclaration ($context)', node.implementsClause,
        allowedKeywords: [Keyword.IMPLEMENTS]);

    for (var member in node.members) {
      _recordDataForNode('ClassDeclaration (member)', member,
          allowedKeywords: memberKeywords);
    }
    super.visitClassDeclaration(node);
  }

  @override
  void visitClassTypeAlias(ClassTypeAlias node) {
    _recordDataForNode('ClassTypeAlias (superclass)', node.superclass);
    var context = 'superclass';
    if (node.withClause != null) {
      _recordTokenType('ClassDeclaration ($context)', node.withClause);
      context = 'with';
    }
    _recordTokenType('ClassDeclaration ($context)', node.implementsClause);
    super.visitClassTypeAlias(node);
  }

  @override
  void visitComment(Comment node) {
    // There are no completions.
    super.visitComment(node);
  }

  @override
  void visitCommentReference(CommentReference node) {
    void recordDataForCommentReference(String context, AstNode node) {
      _recordElementKind(context, node);
      _recordNodeClass(context, node);
      _recordTokenType(context, node);
    }

    recordDataForCommentReference('CommentReference (name)', node.identifier);
    super.visitCommentReference(node);
  }

  @override
  void visitCompilationUnit(CompilationUnit node) {
    enclosingLibrary = node.declaredElement.library;
    typeSystem = enclosingLibrary.typeSystem;

    for (var directive in node.directives) {
      _recordTokenType('CompilationUnit (directive)', directive,
          allowedKeywords: directiveKeywords);
    }
    for (var declaration in node.declarations) {
      _recordDataForNode('CompilationUnit (declaration)', declaration,
          allowedKeywords: declarationKeywords);
    }
    super.visitCompilationUnit(node);

    typeSystem = null;
    enclosingLibrary = null;
  }

  @override
  void visitConditionalExpression(ConditionalExpression node) {
    _recordDataForNode('ConditionalExpression (then)', node.thenExpression,
        allowedKeywords: expressionKeywords);
    _recordDataForNode('ConditionalExpression (else)', node.elseExpression,
        allowedKeywords: expressionKeywords);
    super.visitConditionalExpression(node);
  }

  @override
  void visitConfiguration(Configuration node) {
    // There are no completions.
    super.visitConfiguration(node);
  }

  @override
  void visitConstructorDeclaration(ConstructorDeclaration node) {
    for (var initializer in node.initializers) {
      _recordTokenType('ConstructorDeclaration (initializer)', initializer);
    }
    super.visitConstructorDeclaration(node);
  }

  @override
  void visitConstructorFieldInitializer(ConstructorFieldInitializer node) {
    _recordDataForNode(
        'ConstructorFieldInitializer (expression)', node.expression,
        allowedKeywords: expressionKeywords);
    super.visitConstructorFieldInitializer(node);
  }

  @override
  void visitConstructorName(ConstructorName node) {
    // The token following the `.` is always an identifier.
    super.visitConstructorName(node);
  }

  @override
  void visitContinueStatement(ContinueStatement node) {
    // The token following the `continue` (if there is one) is always a label.
    super.visitContinueStatement(node);
  }

  @override
  void visitDeclaredIdentifier(DeclaredIdentifier node) {
    // There are no completions.
    super.visitDeclaredIdentifier(node);
  }

  @override
  void visitDefaultFormalParameter(DefaultFormalParameter node) {
    _recordDataForNode(
        'DefaultFormalParameter (defaultValue)', node.defaultValue,
        allowedKeywords: expressionKeywords);
    super.visitDefaultFormalParameter(node);
  }

  @override
  void visitDoStatement(DoStatement node) {
    _recordDataForNode('DoStatement (body)', node.body,
        allowedKeywords: statementKeywords);
    _recordDataForNode('DoStatement (condition)', node.condition,
        allowedKeywords: expressionKeywords);
    super.visitDoStatement(node);
  }

  @override
  void visitDottedName(DottedName node) {
    // The components are always identifiers.
    super.visitDottedName(node);
  }

  @override
  void visitDoubleLiteral(DoubleLiteral node) {
    // There are no completions.
    super.visitDoubleLiteral(node);
  }

  @override
  void visitEmptyFunctionBody(EmptyFunctionBody node) {
    // There are no completions.
    super.visitEmptyFunctionBody(node);
  }

  @override
  void visitEmptyStatement(EmptyStatement node) {
    // There are no completions.
    super.visitEmptyStatement(node);
  }

  @override
  void visitEnumConstantDeclaration(EnumConstantDeclaration node) {
    // There are no completions.
    super.visitEnumConstantDeclaration(node);
  }

  @override
  void visitEnumDeclaration(EnumDeclaration node) {
    // There are no completions.
    super.visitEnumDeclaration(node);
  }

  @override
  void visitExportDirective(ExportDirective node) {
    var context = 'uri';
    if (node.configurations.isNotEmpty) {
      _recordTokenType('ImportDirective ($context)', node.configurations[0],
          allowedKeywords: exportKeywords);
      context = 'configurations';
    }
    if (node.combinators.isNotEmpty) {
      _recordTokenType('ImportDirective ($context)', node.combinators[0],
          allowedKeywords: exportKeywords);
    }
    for (var combinator in node.combinators) {
      _recordTokenType('ImportDirective (combinator)', combinator,
          allowedKeywords: exportKeywords);
    }
    super.visitExportDirective(node);
  }

  @override
  void visitExpressionFunctionBody(ExpressionFunctionBody node) {
    _recordTokenType('ExpressionFunctionBody (start)', node,
        allowedKeywords: functionBodyKeywords);
    _recordDataForNode('ExpressionFunctionBody (expression)', node.expression,
        allowedKeywords: expressionKeywords);
    super.visitExpressionFunctionBody(node);
  }

  @override
  void visitExpressionStatement(ExpressionStatement node) {
    _recordDataForNode('ExpressionStatement (start)', node.expression,
        allowedKeywords: expressionKeywords);
    super.visitExpressionStatement(node);
  }

  @override
  void visitExtendsClause(ExtendsClause node) {
    _recordDataForNode('ExtendsClause (type)', node.superclass);
    super.visitExtendsClause(node);
  }

  @override
  void visitExtensionDeclaration(ExtensionDeclaration node) {
    _recordDataForNode('ExtensionDeclaration (type)', node.extendedType);
    for (var member in node.members) {
      _recordDataForNode('ExtensionDeclaration (member)', member,
          allowedKeywords: memberKeywords);
    }
    super.visitExtensionDeclaration(node);
  }

  @override
  void visitExtensionOverride(ExtensionOverride node) {
    // There are no completions.
    super.visitExtensionOverride(node);
  }

  @override
  void visitFieldDeclaration(FieldDeclaration node) {
    // There are no completions.
    super.visitFieldDeclaration(node);
  }

  @override
  void visitFieldFormalParameter(FieldFormalParameter node) {
    // The completions after `this.` are always existing fields.
    super.visitFieldFormalParameter(node);
  }

  @override
  void visitForEachPartsWithDeclaration(ForEachPartsWithDeclaration node) {
    _recordDataForNode(
        'ForEachPartsWithDeclaration (declaration)', node.loopVariable);
    _recordDataForNode('ForEachPartsWithDeclaration (in)', node.iterable,
        allowedKeywords: expressionKeywords);
    super.visitForEachPartsWithDeclaration(node);
  }

  @override
  void visitForEachPartsWithIdentifier(ForEachPartsWithIdentifier node) {
    _recordDataForNode('ForEachPartsWithIdentifier (in)', node.iterable,
        allowedKeywords: expressionKeywords);
    super.visitForEachPartsWithIdentifier(node);
  }

  @override
  void visitForElement(ForElement node) {
    _recordNodeClass('ForElement (parts)', node.forLoopParts);
    _recordTokenType('ForElement (parts)', node.forLoopParts);
    _recordDataForNode('ForElement (body)', node.body);
    super.visitForElement(node);
  }

  @override
  void visitFormalParameterList(FormalParameterList node) {
    for (var parameter in node.parameters) {
      _recordDataForNode('FormalParameterList (parameter)', parameter,
          allowedKeywords: [Keyword.COVARIANT]);
    }
    super.visitFormalParameterList(node);
  }

  @override
  void visitForPartsWithDeclarations(ForPartsWithDeclarations node) {
    _recordDataForNode('ForPartsWithDeclarations (condition)', node.condition,
        allowedKeywords: expressionKeywords);
    for (var updater in node.updaters) {
      _recordDataForNode('ForPartsWithDeclarations (updater)', updater,
          allowedKeywords: expressionKeywords);
    }
    super.visitForPartsWithDeclarations(node);
  }

  @override
  void visitForPartsWithExpression(ForPartsWithExpression node) {
    _recordDataForNode('ForPartsWithDeclarations (condition)', node.condition,
        allowedKeywords: expressionKeywords);
    for (var updater in node.updaters) {
      _recordDataForNode('ForPartsWithDeclarations (updater)', updater,
          allowedKeywords: expressionKeywords);
    }
    super.visitForPartsWithExpression(node);
  }

  @override
  void visitForStatement(ForStatement node) {
    _recordNodeClass('ForElement (parts)', node.forLoopParts);
    _recordTokenType('ForElement (parts)', node.forLoopParts);
    _recordDataForNode('ForElement (body)', node.body,
        allowedKeywords: statementKeywords);
    super.visitForStatement(node);
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    // There are no completions.
    super.visitFunctionDeclaration(node);
  }

  @override
  void visitFunctionDeclarationStatement(FunctionDeclarationStatement node) {
    // There are no completions.
    super.visitFunctionDeclarationStatement(node);
  }

  @override
  void visitFunctionExpression(FunctionExpression node) {
    // There are no completions.
    super.visitFunctionExpression(node);
  }

  @override
  void visitFunctionExpressionInvocation(FunctionExpressionInvocation node) {
    // There are no completions.
    super.visitFunctionExpressionInvocation(node);
  }

  @override
  void visitFunctionTypeAlias(FunctionTypeAlias node) {
    // There are no completions.
    super.visitFunctionTypeAlias(node);
  }

  @override
  void visitFunctionTypedFormalParameter(FunctionTypedFormalParameter node) {
    // There are no completions.
    super.visitFunctionTypedFormalParameter(node);
  }

  @override
  void visitGenericFunctionType(GenericFunctionType node) {
    // There are no completions.
    super.visitGenericFunctionType(node);
  }

  @override
  void visitGenericTypeAlias(GenericTypeAlias node) {
    _recordDataForNode('GenericTypeAlias (functionType)', node.functionType,
        allowedKeywords: [Keyword.FUNCTION]);
    super.visitGenericTypeAlias(node);
  }

  @override
  void visitHideCombinator(HideCombinator node) {
    for (var name in node.hiddenNames) {
      _recordDataForNode('HideCombinator (name)', name);
    }
    super.visitHideCombinator(node);
  }

  @override
  void visitIfElement(IfElement node) {
    _recordDataForNode('IfElement (condition)', node.condition,
        allowedKeywords: expressionKeywords);
    _recordDataForNode('IfElement (then)', node.thenElement);
    _recordDataForNode('IfElement (else)', node.elseElement);
    super.visitIfElement(node);
  }

  @override
  void visitIfStatement(IfStatement node) {
    _recordDataForNode('IfStatement (condition)', node.condition,
        allowedKeywords: expressionKeywords);
    _recordDataForNode('IfStatement (then)', node.thenStatement,
        allowedKeywords: statementKeywords);
    _recordDataForNode('IfStatement (else)', node.elseStatement,
        allowedKeywords: statementKeywords);
    super.visitIfStatement(node);
  }

  @override
  void visitImplementsClause(ImplementsClause node) {
    // At the start of each type name.
    for (var typeName in node.interfaces) {
      _recordDataForNode('ImplementsClause (type)', typeName);
    }
    super.visitImplementsClause(node);
  }

  @override
  void visitImportDirective(ImportDirective node) {
    var context = 'uri';
    if (node.deferredKeyword != null) {
      data.recordTokenType(
          'ImportDirective ($context)', node.deferredKeyword.type);
      context = 'deferred';
    }
    if (node.asKeyword != null) {
      data.recordTokenType('ImportDirective ($context)', node.asKeyword.type);
      context = 'prefix';
    }
    if (node.configurations.isNotEmpty) {
      _recordTokenType('ImportDirective ($context)', node.configurations[0],
          allowedKeywords: importKeywords);
      context = 'configurations';
    }
    if (node.combinators.isNotEmpty) {
      _recordTokenType('ImportDirective ($context)', node.combinators[0],
          allowedKeywords: importKeywords);
    }
    for (var combinator in node.combinators) {
      _recordTokenType('ImportDirective (combinator)', combinator,
          allowedKeywords: importKeywords);
    }
    super.visitImportDirective(node);
  }

  @override
  void visitIndexExpression(IndexExpression node) {
    _recordDataForNode('IndexExpression (index)', node.index,
        allowedKeywords: expressionKeywords);
    _recordTypeMatch(node.index);
    super.visitIndexExpression(node);
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    // There are no completions.
    super.visitInstanceCreationExpression(node);
  }

  @override
  void visitIntegerLiteral(IntegerLiteral node) {
    // There are no completions.
    super.visitIntegerLiteral(node);
  }

  @override
  void visitInterpolationExpression(InterpolationExpression node) {
    _recordDataForNode('InterpolationExpression (expression)', node.expression,
        allowedKeywords: expressionKeywords);
    super.visitInterpolationExpression(node);
  }

  @override
  void visitInterpolationString(InterpolationString node) {
    // There are no completions.
    super.visitInterpolationString(node);
  }

  @override
  void visitIsExpression(IsExpression node) {
    _recordDataForNode('IsExpression (type)', node.type);
    super.visitIsExpression(node);
  }

  @override
  void visitLabel(Label node) {
    // There are no completions.
    super.visitLabel(node);
  }

  @override
  void visitLabeledStatement(LabeledStatement node) {
    _recordDataForNode('LabeledStatement (statement)', node.statement,
        allowedKeywords: statementKeywords);
    super.visitLabeledStatement(node);
  }

  @override
  void visitLibraryDirective(LibraryDirective node) {
    // There are no completions.
    super.visitLibraryDirective(node);
  }

  @override
  void visitLibraryIdentifier(LibraryIdentifier node) {
    // There are no completions.
    super.visitLibraryIdentifier(node);
  }

  @override
  void visitListLiteral(ListLiteral node) {
    for (var element in node.elements) {
      _recordDataForNode('ListLiteral (element)', element,
          allowedKeywords: expressionKeywords);
    }
    super.visitListLiteral(node);
  }

  @override
  void visitMapLiteralEntry(MapLiteralEntry node) {
    _recordDataForNode('MapLiteralEntry (value)', node.value,
        allowedKeywords: expressionKeywords);
    super.visitMapLiteralEntry(node);
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    // There are no completions.
    var element = node.declaredElement;
    if (!element.isStatic) {
      var overriddenMembers = inheritanceManager.getOverridden(
          (element.enclosingElement as ClassElement).thisType,
          Name(element.librarySource.uri, element.name));
      if (overriddenMembers != null) {
        // TODO(brianwilkerson) Should we limit this to the most immediate
        //  override?
        for (var overridden in overriddenMembers) {
          _recordOverride(element, overridden);
        }
      }
    }
    super.visitMethodDeclaration(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    _recordMemberDepth(node.target?.staticType, node.methodName.staticElement);
    super.visitMethodInvocation(node);
  }

  @override
  void visitMixinDeclaration(MixinDeclaration node) {
    var context = 'name';
    if (node.onClause != null) {
      _recordTokenType('MixinDeclaration ($context)', node.onClause,
          allowedKeywords: [Keyword.ON]);
      context = 'on';
    }
    _recordTokenType('MixinDeclaration ($context)', node.implementsClause,
        allowedKeywords: [Keyword.IMPLEMENTS]);

    for (var member in node.members) {
      _recordDataForNode('MixinDeclaration (member)', member,
          allowedKeywords: memberKeywords);
    }
    super.visitMixinDeclaration(node);
  }

  @override
  void visitNamedExpression(NamedExpression node) {
    // Named expressions only occur in argument lists and are handled there.
    super.visitNamedExpression(node);
  }

  @override
  void visitNativeClause(NativeClause node) {
    // There are no completions.
    super.visitNativeClause(node);
  }

  @override
  void visitNativeFunctionBody(NativeFunctionBody node) {
    // There are no completions.
    super.visitNativeFunctionBody(node);
  }

  @override
  void visitNullLiteral(NullLiteral node) {
    // There are no completions.
    super.visitNullLiteral(node);
  }

  @override
  void visitOnClause(OnClause node) {
    for (var constraint in node.superclassConstraints) {
      _recordDataForNode('OnClause (type)', constraint);
    }
    super.visitOnClause(node);
  }

  @override
  void visitParenthesizedExpression(ParenthesizedExpression node) {
    _recordDataForNode('ParenthesizedExpression (expression)', node.expression,
        allowedKeywords: expressionKeywords);
    super.visitParenthesizedExpression(node);
  }

  @override
  void visitPartDirective(PartDirective node) {
    // There are no completions.
    super.visitPartDirective(node);
  }

  @override
  void visitPartOfDirective(PartOfDirective node) {
    // There are no completions.
    super.visitPartOfDirective(node);
  }

  @override
  void visitPostfixExpression(PostfixExpression node) {
    _recordTypeMatch(node.operand);
    super.visitPostfixExpression(node);
  }

  @override
  void visitPrefixedIdentifier(PrefixedIdentifier node) {
    // There are no completions.
    super.visitPrefixedIdentifier(node);
  }

  @override
  void visitPrefixExpression(PrefixExpression node) {
    _recordDataForNode('PrefixExpression (${node.operator})', node.operand,
        allowedKeywords: expressionKeywords);
    _recordTypeMatch(node.operand);
    super.visitPrefixExpression(node);
  }

  @override
  void visitPropertyAccess(PropertyAccess node) {
    _recordMemberDepth(
        node.target?.staticType, node.propertyName.staticElement);
    super.visitPropertyAccess(node);
  }

  @override
  void visitRedirectingConstructorInvocation(
      RedirectingConstructorInvocation node) {
    // There are no completions.
    super.visitRedirectingConstructorInvocation(node);
  }

  @override
  void visitRethrowExpression(RethrowExpression node) {
    // There are no completions.
    super.visitRethrowExpression(node);
  }

  @override
  void visitReturnStatement(ReturnStatement node) {
    _recordDataForNode('ReturnStatement (expression)', node.expression,
        allowedKeywords: expressionKeywords);
    if (node.expression == null) {
      data.recordTokenType('ReturnStatement (expression)', node.semicolon.type);
    }
    super.visitReturnStatement(node);
  }

  @override
  void visitScriptTag(ScriptTag node) {
    // There are no completions.
    super.visitScriptTag(node);
  }

  @override
  void visitSetOrMapLiteral(SetOrMapLiteral node) {
    for (var element in node.elements) {
      _recordDataForNode('SetOrMapLiteral (element)', element,
          allowedKeywords: expressionKeywords);
    }
    super.visitSetOrMapLiteral(node);
  }

  @override
  void visitShowCombinator(ShowCombinator node) {
    for (var name in node.shownNames) {
      _recordDataForNode('ShowCombinator (name)', name);
    }
    super.visitShowCombinator(node);
  }

  @override
  void visitSimpleFormalParameter(SimpleFormalParameter node) {
    // There are no completions.
    super.visitSimpleFormalParameter(node);
  }

  @override
  void visitSimpleStringLiteral(SimpleStringLiteral node) {
    // There are no completions.
    super.visitSimpleStringLiteral(node);
  }

  @override
  void visitSpreadElement(SpreadElement node) {
    _recordDataForNode('SpreadElement (expression)', node.expression,
        allowedKeywords: expressionKeywords);
    super.visitSpreadElement(node);
  }

  @override
  void visitStringInterpolation(StringInterpolation node) {
    // There are no completions.
    super.visitStringInterpolation(node);
  }

  @override
  void visitSuperConstructorInvocation(SuperConstructorInvocation node) {
    // There are no completions.
    super.visitSuperConstructorInvocation(node);
  }

  @override
  void visitSuperExpression(SuperExpression node) {
    // There are no completions.
    super.visitSuperExpression(node);
  }

  @override
  void visitSwitchCase(SwitchCase node) {
    _recordDataForNode('SwitchCase (expression)', node.expression,
        allowedKeywords: expressionKeywords);
    for (var statement in node.statements) {
      _recordDataForNode('SwitchCase (statement)', statement,
          allowedKeywords: statementKeywords);
    }
    super.visitSwitchCase(node);
  }

  @override
  void visitSwitchDefault(SwitchDefault node) {
    for (var statement in node.statements) {
      _recordDataForNode('SwitchDefault (statement)', statement,
          allowedKeywords: statementKeywords);
    }
    super.visitSwitchDefault(node);
  }

  @override
  void visitSwitchStatement(SwitchStatement node) {
    _recordDataForNode('SwitchStatement (expression)', node.expression,
        allowedKeywords: expressionKeywords);
    super.visitSwitchStatement(node);
  }

  @override
  void visitSymbolLiteral(SymbolLiteral node) {
    // There are no completions.
    super.visitSymbolLiteral(node);
  }

  @override
  void visitThisExpression(ThisExpression node) {
    // There are no completions.
    super.visitThisExpression(node);
  }

  @override
  void visitThrowExpression(ThrowExpression node) {
    _recordDataForNode('ThrowExpression (expression)', node.expression,
        allowedKeywords: expressionKeywords);
    super.visitThrowExpression(node);
  }

  @override
  void visitTopLevelVariableDeclaration(TopLevelVariableDeclaration node) {
    // There are no completions.
    super.visitTopLevelVariableDeclaration(node);
  }

  @override
  void visitTryStatement(TryStatement node) {
    var context = 'try';
    for (var clause in node.catchClauses) {
      _recordTokenType('TryStatement ($context)', clause,
          allowedKeywords: [Keyword.ON]);
      context = 'catch';
    }
    if (node.finallyKeyword != null) {
      data.recordTokenType('TryStatement ($context)', node.finallyKeyword.type);
    }
    super.visitTryStatement(node);
  }

  @override
  void visitTypeArgumentList(TypeArgumentList node) {
    for (var typeArgument in node.arguments) {
      _recordDataForNode('TypeArgumentList (argument)', typeArgument);
    }
    super.visitTypeArgumentList(node);
  }

  @override
  void visitTypeName(TypeName node) {
    // There are no completions.
    super.visitTypeName(node);
  }

  @override
  void visitTypeParameter(TypeParameter node) {
    if (node.bound != null) {
      _recordDataForNode('TypeParameter (bound)', node.bound);
    }
    super.visitTypeParameter(node);
  }

  @override
  void visitTypeParameterList(TypeParameterList node) {
    // There are no completions.
    super.visitTypeParameterList(node);
  }

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    var keywords = node.parent.parent is FieldDeclaration
        ? [Keyword.COVARIANT, ...expressionKeywords]
        : expressionKeywords;
    _recordDataForNode('VariableDeclaration (initializer)', node.initializer,
        allowedKeywords: keywords);
    super.visitVariableDeclaration(node);
  }

  @override
  void visitVariableDeclarationList(VariableDeclarationList node) {
    // There are no completions.
    super.visitVariableDeclarationList(node);
  }

  @override
  void visitVariableDeclarationStatement(VariableDeclarationStatement node) {
    // There are no completions.
    super.visitVariableDeclarationStatement(node);
  }

  @override
  void visitWhileStatement(WhileStatement node) {
    _recordDataForNode('WhileStatement (condition)', node.condition,
        allowedKeywords: expressionKeywords);
    _recordDataForNode('WhileStatement (body)', node.body,
        allowedKeywords: statementKeywords);
    super.visitWhileStatement(node);
  }

  @override
  void visitWithClause(WithClause node) {
    for (var typeName in node.mixinTypes) {
      _recordDataForNode('WithClause (type)', typeName);
    }
    super.visitWithClause(node);
  }

  @override
  void visitYieldStatement(YieldStatement node) {
    _recordDataForNode('YieldStatement (expression)', node.expression,
        allowedKeywords: expressionKeywords);
    super.visitYieldStatement(node);
  }

  /// Return the depth of the given [element]. For example:
  /// 0: imported
  /// 1: prefix
  /// 2: top-level decl
  /// 3: class member
  /// 4+: local function
  int _depth(Element element) {
    if (element.library != enclosingLibrary) {
      return 0;
    }
    var depth = 0;
    var currentElement = element;
    while (currentElement != enclosingLibrary) {
      depth++;
      currentElement = currentElement.enclosingElement;
    }
    return depth;
  }

  /// Return the first child of the [node] that is neither a comment nor an
  /// annotation.
  SyntacticEntity _firstChild(AstNode node) {
    var children = node.childEntities.toList();
    for (int i = 0; i < children.length; i++) {
      var child = children[i];
      if (child is! Comment && child is! Annotation) {
        return child;
      }
    }
    return null;
  }

  /// Return the element associated with the left-most identifier that is a
  /// child of the [node].
  Element _leftMostElement(AstNode node) =>
      _leftMostIdentifier(node)?.staticElement;

  /// Return the left-most child of the [node] if it is a simple identifier, or
  /// `null` if the left-most child is not a simple identifier. Comments and
  /// annotations are ignored for this purpose.
  SimpleIdentifier _leftMostIdentifier(AstNode node) {
    var currentNode = node;
    while (currentNode != null && currentNode is! SimpleIdentifier) {
      var firstChild = _firstChild(currentNode);
      if (firstChild is AstNode) {
        currentNode = firstChild;
      } else {
        currentNode = null;
      }
    }
    if (currentNode is SimpleIdentifier && currentNode.inDeclarationContext()) {
      // TODO(brianwilkerson) Explore recording when the left-most identifier is
      //  in a declaration context to help align identifier counts (from the
      //  token type list) with the element counts.
      return null;
    }
    return currentNode;
  }

  /// Return the element kind of the element associated with the left-most
  /// identifier that is a child of the [node].
  ElementKind _leftMostKind(AstNode node) {
    if (node is InstanceCreationExpression) {
      return convertElementToElementKind(node.staticElement);
    }
    var element = _leftMostElement(node);
    if (element == null) {
      return null;
    }
    if (element is ClassElement) {
      var parent = node.parent;
      if (parent is Annotation && parent.arguments != null) {
        element = parent.element;
      }
    }
    return convertElementToElementKind(element);
  }

  /// Return the left-most token that is a child of the [node].
  Token _leftMostToken(AstNode node) {
    SyntacticEntity entity = node;
    while (entity is AstNode) {
      entity = _firstChild(entity as AstNode);
    }
    if (entity is Token) {
      return entity;
    }
    return null;
  }

  /// Return the distance between the [reference] and the referenced local
  /// [variable], where the distance is defined to be the number of variable
  /// declarations between the local variable and the reference.
  int _localVariableDistance(AstNode reference, LocalVariableElement variable) {
    var distance = 0;
    var node = reference;
    while (node != null) {
      if (node is ForStatement) {
        var loopParts = node.forLoopParts;
        if (loopParts is ForPartsWithDeclarations) {
          for (var declaredVariable in loopParts.variables.variables.reversed) {
            if (declaredVariable.declaredElement == variable) {
              return distance;
            }
            distance++;
          }
        } else if (loopParts is ForEachPartsWithDeclaration) {
          if (loopParts.loopVariable.declaredElement == variable) {
            return distance;
          }
          distance++;
        }
      } else if (node is VariableDeclarationStatement) {
        for (var declaredVariable in node.variables.variables.reversed) {
          if (declaredVariable.declaredElement == variable) {
            return distance;
          }
          distance++;
        }
      } else if (node is CatchClause) {
        if (node.exceptionParameter.staticElement == variable ||
            node.stackTraceParameter?.staticElement == variable) {
          return distance;
        }
      }
      if (node is Statement) {
        var parent = node.parent;
        var statements = const <Statement>[];
        if (parent is Block) {
          statements = parent.statements;
        } else if (parent is SwitchCase) {
          statements = parent.statements;
        } else if (parent is SwitchDefault) {
          statements = parent.statements;
        }
        var index = statements.indexOf(node);
        for (int i = 0; i < index; i++) {
          var statement = statements[i];
          if (statement is VariableDeclarationStatement) {
            for (var declaredVariable
                in statement.variables.variables.reversed) {
              if (declaredVariable.declaredElement == variable) {
                return distance;
              }
              distance++;
            }
          }
        }
      }
      node = node.parent;
    }
    return -1;
  }

  /// Return the number of functions between the [reference] and the [function]
  /// in which the referenced parameter is declared.
  int _parameterReferenceDepth(AstNode reference, Element function) {
    var depth = 0;
    var node = reference;
    while (node != null) {
      if (node is MethodDeclaration) {
        if (node.declaredElement == function) {
          return depth;
        }
        depth++;
      } else if (node is ConstructorDeclaration) {
        if (node.declaredElement == function) {
          return depth;
        }
        depth++;
      } else if (node is FunctionExpression) {
        if (node.declaredElement == function) {
          return depth;
        }
        depth++;
      }
      node = node.parent;
    }
    return -1;
  }

  /// Record information about the given [node] occurring in the given
  /// [context].
  void _recordDataForNode(String context, AstNode node,
      {List<Keyword> allowedKeywords = noKeywords}) {
    _recordElementKind(context, node);
    _recordNodeClass(context, node);
    _recordReferenceDepth(node);
    _recordTokenDistance(node);
    _recordTokenType(context, node, allowedKeywords: allowedKeywords);
  }

  /// Record the [distance] from a reference to the declaration. The kind of
  /// distance is described by the [descriptor].
  void _recordDistance(String descriptor, int distance) {
    data.recordDistance(descriptor, distance);
  }

  /// Record the element kind of the element associated with the left-most
  /// identifier that is a child of the [node] in the given [context].
  void _recordElementKind(String context, AstNode node) {
    if (node != null) {
      var kind = _leftMostKind(node);
      if (kind != null) {
        data.recordElementKind(context, kind);
        if (node is Expression) {
          data.recordElementKind('Expression', kind);
        } else if (node is Statement) {
          data.recordElementKind('Statement', kind);
        }
      }
    }
  }

  /// Record the distance between the static type of the target (the
  /// [targetType]) and the [element] to which the member reference was
  /// resolved.
  void _recordMemberDepth(DartType targetType, Element element) {
    if (targetType is InterfaceType) {
      var subclass = targetType.element;
      var extension = element.thisOrAncestorOfType<ExtensionElement>();
      if (extension != null) {
        _recordDistance('member (extension)', 0);
        return;
      }
      // TODO(brianwilkerson) It might be interesting to also know whether the
      //  [element] was found in a class, interface, or mixin.
      var superclass = element.thisOrAncestorOfType<ClassElement>();
      if (superclass != null) {
        int getSuperclassDepth() {
          var depth = 0;
          var currentClass = subclass;
          while (currentClass != null) {
            if (currentClass == superclass) {
              return depth;
            }
            for (var mixin in currentClass.mixins.reversed) {
              depth++;
              if (mixin.element == superclass) {
                return depth;
              }
            }
            depth++;
            currentClass = currentClass.supertype?.element;
          }
          return -1;
        }

        var notFound = 0xFFFF;
        int getInterfaceDepth(ClassElement currentClass) {
          if (currentClass == null) {
            return notFound;
          } else if (currentClass == superclass) {
            return 0;
          }
          var minDepth = getInterfaceDepth(currentClass.supertype?.element);
          for (var mixin in currentClass.mixins) {
            var depth = getInterfaceDepth(mixin.element);
            if (depth < minDepth) {
              minDepth = depth;
            }
          }
          for (var interface in currentClass.interfaces) {
            var depth = getInterfaceDepth(interface.element);
            if (depth < minDepth) {
              minDepth = depth;
            }
          }
          return minDepth + 1;
        }

        int superclassDepth = getSuperclassDepth();
        // TODO(brianwilkerson) Consider cross referencing with the depth of the
        //  class containing the reference.
        if (superclassDepth >= 0) {
          _recordDistance('member (superclass)', superclassDepth);
        } else {
          int interfaceDepth = getInterfaceDepth(subclass);
          if (interfaceDepth < notFound) {
            _recordDistance('member (interface)', interfaceDepth);
          } else {
            _recordDistance('member (not found)', 0);
          }
        }
      }
    }
  }

  /// Record the class of the [node] in the given [context].
  void _recordNodeClass(String context, AstNode node) {
    if (node != null) {
      data.recordNodeClass(context, node);
    }
  }

  void _recordOverride(
      ExecutableElement override, ExecutableElement overridden) {
    var positionalInOverride = <ParameterElement>[];
    var namedInOverride = <String, ParameterElement>{};
    var positionalInOverridden = <ParameterElement>[];
    var namedInOverridden = <String, ParameterElement>{};
    for (var param in override.parameters) {
      if (param.isPositional) {
        positionalInOverride.add(param);
      } else {
        namedInOverride[param.name] = param;
      }
    }
    for (var param in overridden.parameters) {
      if (param.isPositional) {
        positionalInOverridden.add(param);
      } else {
        namedInOverridden[param.name] = param;
      }
    }

    void recordParameterOverride(ParameterElement overrideParameter,
        ParameterElement overriddenParameter) {
      var overrideType = overrideParameter?.type;
      var overriddenType = overriddenParameter?.type;
      if (overrideType == null ||
          overrideType.isDynamic ||
          overriddenType == null ||
          overriddenType.isDynamic) {
        return;
      }
      _recordTypeRelationships(
          'parameter override', overriddenType, overrideType);
    }

    int count =
        math.min(positionalInOverride.length, positionalInOverridden.length);
    for (int i = 0; i < count; i++) {
      recordParameterOverride(
          positionalInOverride[i], positionalInOverridden[i]);
    }
    for (var name in namedInOverride.keys) {
      var overrideParameter = namedInOverridden[name];
      var overriddenParameter = namedInOverridden[name];
      recordParameterOverride(overrideParameter, overriddenParameter);
    }
  }

  /// Record the depth of the element associated with the left-most identifier
  /// that is a child of the given [node].
  void _recordReferenceDepth(AstNode node) {
    var reference = _leftMostIdentifier(node);
    var element = reference?.staticElement;
    if (element is ParameterElement) {
      var definingElement = element.enclosingElement;
      var depth = _parameterReferenceDepth(node, definingElement);
      _recordDistance('function depth of referenced parameter', depth);
    } else if (element is LocalVariableElement) {
      // TODO(brianwilkerson) This ignores the fact that nested functions can
      //  reference variables declared in enclosing functions. Consider
      //  additionally measuring the number of function boundaries that are
      //  crossed and then reporting the distance with a label such as
      //  'local variable ($boundaryCount)'.
      var distance = _localVariableDistance(node, element);
      _recordDistance('distance to local variable', distance);
    } else if (element != null) {
      // TODO(brianwilkerson) We might want to cross reference the depth of
      //  the declaration with the depth of the reference to see whether there
      //  is a pattern.
      _recordDistance(
          'declaration depth of referenced element', _depth(element));
    }
  }

  /// Record the number of tokens between a given identifier and the nearest
  /// previous token with the same lexeme.
  void _recordTokenDistance(AstNode node) {
    var identifier = _leftMostIdentifier(node);
    if (identifier != null) {
      int distance() {
        var token = identifier.token;
        var lexeme = token.lexeme;
        var distance = 1;
        token = token.previous;
        while (!token.isEof && distance <= 100) {
          if (token.lexeme == lexeme) {
            return distance;
          }
          distance++;
          token = token.previous;
        }
        return -1;
      }

      data.recordTokenStream(distance());
    }
  }

  /// Record the token type of the left-most token that is a child of the
  /// [node] in the given [context].
  void _recordTokenType(String context, AstNode node,
      {List<Keyword> allowedKeywords = noKeywords}) {
    if (node != null) {
      var token = _leftMostToken(node);
      if (token != null) {
        var type = token.type;
        if (token.isKeyword && token.keyword.isBuiltInOrPseudo) {
          // These keywords can be used as identifiers, so determine whether it
          // is being used as a keyword or an identifier.
          if (!allowedKeywords.contains(token.keyword)) {
            type = TokenType.IDENTIFIER;
          }
        }
        data.recordTokenType(context, type);
        if (node is Expression) {
          data.recordTokenType('Expression', type);
        } else if (node is Statement) {
          data.recordTokenType('Statement', type);
        }
      }
    }
  }

  /// Record information about how the argument as a whole and the first token
  /// in the expression match the type of the associated parameter.
  void _recordTypeMatch(Expression argument) {
    var parameterType = argument.staticParameterElement?.type;
    if (parameterType == null || parameterType.isDynamic) {
      return;
    }
    var argumentType = argument.staticType;
    if (argumentType != null) {
      _recordTypeRelationships('argument (whole)', parameterType, argumentType);
    }
    var identifier = _leftMostIdentifier(argument);
    if (identifier != null) {
      var firstTokenType = identifier.staticType;
      if (firstTokenType == null) {
        var element = identifier.staticElement;
        if (element is ClassElement) {
          // This is effectively treating a reference to a class name as having
          // the same type as an instance of the class, which isn't valid, but
          // on the other hand, the spec doesn't define the static type of a
          // class name in this context so anything we do will be wrong in some
          // sense.
          firstTokenType = element.thisType;
        }
      }
      if (firstTokenType != null) {
        _recordTypeRelationships(
            'argument (first token)', parameterType, firstTokenType);
      }
    }
  }

  /// Record information about how the [parameterType] and [argumentType] are
  /// related, using the [descriptor] to differentiate between the counts.
  void _recordTypeRelationships(
      String descriptor, DartType parameterType, DartType argumentType) {
    if (argumentType == parameterType) {
      data.recordTypeMatch('$descriptor', 'exact');
    } else if (typeSystem.isSubtypeOf(argumentType, parameterType)) {
      data.recordTypeMatch('$descriptor', 'subtype');
    } else if (typeSystem.isSubtypeOf(parameterType, argumentType)) {
      data.recordTypeMatch('$descriptor', 'supertype');
    } else {
      data.recordTypeMatch('$descriptor', 'unrelated');
    }
  }
}

/// An object used to compute metrics for a single file or directory.
class RelevanceMetricsComputer {
  /// The metrics data that was computed.
  final RelevanceData data = RelevanceData();

  /// Initialize a newly created metrics computer that can compute the metrics
  /// in one or more files and directories.
  RelevanceMetricsComputer();

  /// Compute the metrics for the file(s) in the [rootPath].
  void compute(String rootPath) async {
    final collection = AnalysisContextCollection(
      includedPaths: [rootPath],
      resourceProvider: PhysicalResourceProvider.INSTANCE,
    );
    final collector = RelevanceDataCollector(data);

    for (var context in collection.contexts) {
      for (var filePath in context.contextRoot.analyzedFiles()) {
        if (AnalysisEngine.isDartFileName(filePath)) {
          try {
            ResolvedUnitResult resolvedUnitResult =
                await context.currentSession.getResolvedUnit(filePath);
            //
            // Check for errors that cause the file to be skipped.
            //
            if (resolvedUnitResult.state != ResultState.VALID) {
              print('File $filePath skipped because it could not be analyzed.');
              print('');
              continue;
            } else if (hasError(resolvedUnitResult)) {
              print('File $filePath skipped due to errors:');
              for (var error in resolvedUnitResult.errors) {
                print('  ${error.toString()}');
              }
              print('');
              continue;
            }

            resolvedUnitResult.unit.accept(collector);
          } catch (exception) {
            print('Exception caught analyzing: "$filePath"');
            print(exception.toString());
          }
        }
      }
    }
  }

  /// Write a report of the metrics that were computed to the [sink].
  void writeMetrics(StringSink sink) {
    sink.writeln('');
    _writeSideBySide(
        sink,
        [data.byTokenType, data.byElementKind, data.byNodeClass],
        ['Token Types', 'Element Kinds', 'Node Classes']);
    sink.writeln('');
    sink.writeln('Type relationships');
    _writeContextMap(sink, data.byTypeMatch);
    sink.writeln('');
    sink.writeln('Structural indicators');
    _writeContextMap(sink, data.byDistance);
    _writeTokenData(sink, data.tokenDistances);
  }

  /// Return the minimum widths for each of the columns in the given [table].
  ///
  /// The table is represented as a list or rows, where each row is a list of the
  /// contents of the cells in that row.
  ///
  /// Throws an [ArgumentError] if the table is empty or if the rows do not
  /// contain the same number of cells.
  List<int> _computeColumnWidths(List<List<String>> table) {
    if (table.isEmpty) {
      throw ArgumentError('table cannot be empty');
    }
    var columnCount = table[0].length;
    if (columnCount == 0) {
      throw ArgumentError('rows cannot be empty');
    }
    var columnWidths = List<int>.filled(columnCount, 0);
    for (var row in table) {
      var rowLength = row.length;
      if (rowLength > 0) {
        if (rowLength != columnCount) {
          throw ArgumentError(
              'non-empty rows must contain the same number of columns');
        }
        for (int i = 0; i < rowLength; i++) {
          var cellWidth = row[i].length;
          columnWidths[i] = math.max(columnWidths[i], cellWidth);
        }
      }
    }
    return columnWidths;
  }

  Iterable<List<String>> _convertColumnsToRows(
      Iterable<List<String>> columns) sync* {
    var maxRowCount = columns.fold<int>(
        0, (previous, column) => math.max(previous, column.length));
    for (var i = 0; i < maxRowCount; i++) {
      var row = <String>[];
      for (var column in columns) {
        if (i < column.length) {
          row.add(column[i]);
        } else {
          row.add('');
        }
      }
      yield row;
    }
  }

  /// Convert the contents of a single [map] into the values for each row in the
  /// column occupied by the map.
  List<String> _convertMap<T extends Object>(String context, Map<T, int> map) {
    var columns = <String>[];
    if (map == null) {
      return columns;
    }
    var entries = map.entries.toList()
      ..sort((first, second) {
        return second.value.compareTo(first.value);
      });
    var total = 0;
    for (var entry in entries) {
      total += entry.value;
    }
    columns.add('$context ($total)');
    for (var entry in entries) {
      var value = entry.value;
      var percent = _formatPercent(value, total);
      columns.add('  $percent%: ${entry.key} ($value)');
    }
    return columns;
  }

  /// Convert the data in a list of [maps] into a table with one column per map.
  /// The columns will be titled using the given [columnTitles].
  List<List<String>> _createTable(
      List<Map<String, Map<String, int>>> maps, List<String> columnTitles) {
    var uniqueContexts = <String>{};
    for (var map in maps) {
      uniqueContexts.addAll(map.keys);
    }
    var contexts = uniqueContexts.toList()..sort();

    var blankRow = <String>[];
    var table = <List<String>>[];
    table.add(columnTitles);
    for (var context in contexts) {
      var columns = maps.map((map) => _convertMap(context, map[context]));
      table.addAll(_convertColumnsToRows(columns));
      table.add(blankRow);
    }
    return table;
  }

  /// Compute and format a percentage for the fraction [value] / [total].
  String _formatPercent(int value, int total) {
    var percent = ((value / total) * 100).toStringAsFixed(1);
    if (percent.length == 3) {
      percent = '  $percent';
    } else if (percent.length == 4) {
      percent = ' $percent';
    }
    return percent;
  }

  /// Write a [contextMap] containing one kind of metric data to the [sink].
  void _writeContextMap(
      StringSink sink, Map<String, Map<String, int>> contextMap) {
    var contexts = contextMap.keys.toList()..sort();
    for (var context in contexts) {
      var lines = _convertMap(context, contextMap[context]);
      for (var line in lines) {
        sink.writeln('  $line');
      }
    }
  }

  /// Write the given [maps] to the given [sink], formatting them as side-by-side
  /// columns titled by the given [columnTitles].
  void _writeSideBySide(StringSink sink,
      List<Map<String, Map<String, int>>> maps, List<String> columnTitles) {
    var table = _createTable(maps, columnTitles);
    _writeTable(sink, table);
  }

  /// Write the given [table] to the [sink].
  ///
  /// The table is represented as a list or rows, where each row is a list of the
  /// contents of the cells in that row.
  ///
  /// Throws an [ArgumentError] if the table is empty or if the rows do not
  /// contain the same number of cells.
  void _writeTable(StringSink sink, List<List<String>> table) {
    var columnWidths = _computeColumnWidths(table);
    for (var row in table) {
      int lastNonEmpty = row.length - 1;
      while (lastNonEmpty > 0) {
        if (row[lastNonEmpty].isNotEmpty) {
          break;
        }
        lastNonEmpty--;
      }
      for (int i = 0; i <= lastNonEmpty; i++) {
        var cellContent = row[i];
        var columnWidth = columnWidths[i];
        var padding = columnWidth - cellContent.length;
        sink.write(cellContent);
        if (i < lastNonEmpty) {
          sink.write(' ' * (padding + 2));
        }
      }
      sink.writeln();
    }
  }

  /// Write information about the number of identifiers that occur within a
  /// given distance of the nearest previous occurrence of the same identifier.
  void _writeTokenData(StringSink sink, Map<int, int> distances) {
    var firstColumn =
        _convertMap('distance to previous matching token', distances);
    var secondColumn = <String>[];
    var total = distances.values
        .fold<int>(0, (previous, current) => previous + current);
    secondColumn.add('matching tokens within a given distance ($total)');
    var cumulative = 0;
    for (int i = 1; i <= 100; i++) {
      cumulative += distances[i] ?? 0;
      var percent = _formatPercent(cumulative, total);
      secondColumn.add('  $percent%: $i');
    }

    sink.writeln('');
    sink.writeln('Token stream analysis');
    var table = _convertColumnsToRows([firstColumn, secondColumn]).toList();
    _writeTable(sink, table);
  }

  /// Return `true` if the [result] contains an error.
  static bool hasError(ResolvedUnitResult result) {
    for (var error in result.errors) {
      if (error.severity == Severity.error) {
        return true;
      }
    }
    return false;
  }
}
