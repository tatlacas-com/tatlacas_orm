import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:analyzer/dart/element/visitor.dart';
import 'package:build/build.dart';
import 'package:source_gen/source_gen.dart';
import 'package:tatlacas_orm/src/builders/annotations.dart';
import 'package:tatlacas_orm/src/models/entity.dart';

class _ExtraField {
  _ExtraField({
    required this.notNull,
    required this.type,
    required this.typeFull,
  });

  final bool notNull;
  final String type;
  final String typeFull;
}

// Define a visitor class to search for a property with a specific name.
class PropertyFinder extends RecursiveElementVisitor<void> {
  PropertyFinder(this.propertyName);
  final String propertyName;
  FieldElement? foundProperty;

  @override
  void visitFieldElement(FieldElement element) {
    if (element.name == propertyName) {
      foundProperty = element;
    }
  }
}

class DbColumnGenerator extends GeneratorForAnnotation<OrmEntity> {
  bool _hasDbAnnotation(FieldElement field) {
    return const TypeChecker.fromRuntime(OrmColumn)
            .hasAnnotationOfExact(field) ||
        const TypeChecker.fromRuntime(CopyableProp)
            .hasAnnotationOfExact(field) ||
        const TypeChecker.fromRuntime(NullableProp).hasAnnotationOfExact(field);
  }

  @override
  String generateForAnnotatedElement(
    Element element,
    ConstantReader annotation,
    BuildStep buildStep,
  ) {
    final classElement = element as ClassElement;
    final className = classElement.name;

    final tableName = annotation.read('tableName').literalValue as String?;

    if (!const TypeChecker.fromRuntime(Entity).isAssignableFrom(element)) {
      throw Exception('$className is not an Entity class');
    }

    final fields = classElement.fields;

    final mixinCode = StringBuffer();
    final metaCode = StringBuffer();
    final columnsList = StringBuffer();
    final copyWithList = StringBuffer();
    final getList = StringBuffer();
    final copyWithPropsList = StringBuffer();
    final propsList = StringBuffer();

    mixinCode.writeln(
        'mixin _${className}Mixin on Entity<$className, ${className}Meta> {');
    metaCode.writeln('''
typedef ${className}Orm
    = OrmEngine<$className, ${className}Meta, DbContext<$className>>;

class ${className}Meta extends  EntityMeta<$className> {     
  const ${className}Meta();

  @override
  String get tableName => '${tableName ?? convertClassNameToSnakeCase(className)}';
          ''');

    metaCode.writeln('''
  @override
  ColumnDefinition<$className, String> get id => 
  ColumnDefinition<$className, String>(
        'id',
        primaryKey: true,
        write: (entity) => entity.id,
        read: (json, entity, value) =>
            entity.copyWith(id: value, json: json),
      );

  @override
  ColumnDefinition<$className, DateTime> get createdAt =>
      ColumnDefinition<$className, DateTime>(
        'createdAt',
        write: (entity) => entity.createdAt,
        read: (json, entity, value) =>
            entity.copyWith(createdAt: value, json: json),
      );

  @override
  ColumnDefinition<$className, DateTime> get updatedAt =>
      ColumnDefinition<$className, DateTime>(
        'updatedAt',
        write: (entity) => entity.updatedAt,
        read: (json, entity, value) =>
            entity.copyWith(updatedAt: value, json: json),
      );
    ''');

    mixinCode.writeln('''
  
  static const ${className}Meta _meta = ${className}Meta();

  @override
  ${className}Meta get meta => _meta;
    ''');
    final Map<String, _ExtraField> extraFields = {};
    extraFields.addEntries(
      fields
          .where((field) => field.isFinal && !_hasDbAnnotation(field))
          .map(
            (e) => MapEntry(
              e.name,
              _ExtraField(
                type: e.type.getDisplayString(withNullability: false),
                typeFull: e.type.getDisplayString(withNullability: true),
                notNull: e.type.nullabilitySuffix == NullabilitySuffix.none,
              ),
            ),
          )
          .toList(),
    );
    for (final field in fields) {
      if (const TypeChecker.fromRuntime(OrmColumn)
          .hasAnnotationOfExact(field)) {
        final fieldName = field.name;
        var fieldType = field.type.getDisplayString(withNullability: false);
        final fieldTypeFull =
            field.type.getDisplayString(withNullability: true);

        final isDefaultType =
            ['String', 'DateTime', 'int', 'bool', 'double'].contains(fieldType);

        final isList = fieldType.startsWith('List');
        if (isList) {
          final start = fieldTypeFull.indexOf('<');
          final end = fieldTypeFull.indexOf('>');
          if (start != -1) {
            fieldType = fieldTypeFull.substring(start + 1, end);
          }
        }

        final fieldNameCamel = _toUpperCamelCase(fieldName);
        final fieldMetadata = field.metadata;
        final List<ElementAnnotation> fieldAnnotations = [];
        for (final annotation in fieldMetadata) {
          final tp = annotation.computeConstantValue()?.type;
          if (tp == null) {
            continue;
          }
          if (const TypeChecker.fromRuntime(OrmColumn).isExactlyType(tp)) {
            columnsList.writeln('$fieldName,');
            fieldAnnotations.add(annotation);
          }
        }

        propsList.writeln('$fieldName,');
        getList.writeln('$fieldTypeFull get $fieldName;');

        for (final annotation in fieldAnnotations) {
          final dbColumnAnnotation = annotation.computeConstantValue()!;

          final String name =
              dbColumnAnnotation.getField('name')?.toStringValue() ?? fieldName;
          final jsonEncoded = !isDefaultType ||
              (dbColumnAnnotation.getField('encodedJson')?.toBoolValue() ??
                  false);
          final String? alias =
              dbColumnAnnotation.getField('alias')?.toStringValue() ??
                  (jsonEncoded && isDefaultType
                      ? fieldName.replaceAll('Json', '')
                      : null);

          final String? writeFn =
              dbColumnAnnotation.getField('writeFn')?.toStringValue();

          final bool hasRead = isDefaultType &&
              (dbColumnAnnotation.getField('hasRead')?.toBoolValue() ?? false);
          final bool hasWrite = isDefaultType &&
              (dbColumnAnnotation.getField('hasWrite')?.toBoolValue() ?? false);
          final bool primaryKey = isDefaultType &&
              (dbColumnAnnotation.getField('primaryKey')?.toBoolValue() ??
                  false);
          final bool autoIncrementPrimary = isDefaultType &&
              (dbColumnAnnotation
                      .getField('autoIncrementPrimary')
                      ?.toBoolValue() ??
                  false);
          final bool notNull =
              dbColumnAnnotation.getField('notNull')?.toBoolValue() ??
                  (field.type.nullabilitySuffix == NullabilitySuffix.none);
          final bool unique = isDefaultType &&
              (dbColumnAnnotation.getField('unique')?.toBoolValue() ?? false);
          dynamic defaultValue = dbColumnAnnotation.getField('defaultValue');
          if (field.type.isDartCoreBool) {
            defaultValue =
                dbColumnAnnotation.getField('defaultValue')?.toBoolValue();
          } else if (field.type.isDartCoreInt) {
            defaultValue =
                dbColumnAnnotation.getField('defaultValue')?.toIntValue();
          } else if (field.type.isDartCoreDouble) {
            defaultValue =
                dbColumnAnnotation.getField('defaultValue')?.toDoubleValue();
          } else {
            defaultValue =
                dbColumnAnnotation.getField('defaultValue')?.toStringValue();
          }
          var columnType = fieldType;
          String? jsonEncodedType;
          final annotationSource = annotation.toSource().trim();

          if (isDefaultType) {
            final start = annotationSource.indexOf('<');
            final end = annotationSource.indexOf('>');
            if (start != -1) {
              final t = annotationSource.substring(start + 1, end);
              if (jsonEncoded && isDefaultType) {
                jsonEncodedType = t;
              } else {
                columnType = t;
              }
            }
          } else {
            columnType = 'String';
          }

          FieldElement? aliasProperty;
          bool aliasNotNull = false;
          if (alias != null && (hasRead || jsonEncoded)) {
            final finder = PropertyFinder(alias);
            classElement.accept(finder);
            aliasProperty = finder.foundProperty!;
            aliasNotNull =
                aliasProperty.type.nullabilitySuffix == NullabilitySuffix.none;
            if (aliasProperty.type.isDartCoreList) {
              jsonEncodedType =
                  aliasProperty.type.getDisplayString(withNullability: false);
            }
            mixinCode.writeln('''
  $jsonEncodedType${aliasNotNull ? '' : '?'} get $alias;
 ''');
          }

          if (!isDefaultType) {
            mixinCode.writeln('''
  $className read$fieldNameCamel(Map<String, dynamic> json, value){
 ''');
            if (isList) {
              mixinCode.writeln('''
    List<$fieldType>? items;
    if (value != null) {
      List<dynamic> map = jsonDecode(value);
      items = map.map<$fieldType>((e) => $fieldType.fromMap(e)).toList();
    }
    return copyWith(
      $fieldName: ${notNull ? 'items' : 'CopyWith(items)'},
    );
  }
 ''');
            } else {
              mixinCode.writeln('''
    $fieldType? item;
    if (value != null) {
      Map<String, dynamic> map = jsonDecode(value);
      item = $fieldType.fromMap(map);
    }
    return copyWith(
      $fieldName: ${notNull ? 'item' : 'CopyWith(item)'},
    );
  }
 ''');
            }
          }

          if (hasRead) {
            mixinCode.writeln('''
  $className read$fieldNameCamel(Map<String, dynamic> json, value);
 ''');
          } else if (jsonEncoded && isDefaultType) {
            mixinCode.writeln('''
  $className read$fieldNameCamel(Map<String, dynamic> json, value){
    $jsonEncodedType? $alias;
    final val = value != null && value != 'null' ? value : null;
    if (val != null) {
      Map<String, dynamic> map = jsonDecode(val);
      $alias = $jsonEncodedType.fromMap(map);
    }
    return copyWith(
      $fieldName: ${notNull ? 'val' : 'CopyWith(val)'},
      $alias: ${aliasNotNull ? alias : 'CopyWith($alias)'},
      json: json,
    );
  }
 ''');
          }
          if (hasWrite) {
            mixinCode.writeln('''
  $columnType? write$fieldNameCamel();
 ''');
          }

          metaCode.writeln('''
      ColumnDefinition<$className, $columnType> get $fieldName =>
        ColumnDefinition<$className, $columnType>(
          '$name',
    ''');
          if (alias != null) {
            metaCode.writeln('''
           alias: '$alias',
    ''');
          }
          if (jsonEncoded && isDefaultType) {
            metaCode.writeln('''
           jsonEncodeAlias: $jsonEncoded,
    ''');
          }
          if (primaryKey == true) {
            metaCode.writeln('''
           primaryKey: $primaryKey,
    ''');
          }
          if (unique == true) {
            metaCode.writeln('''
           unique: $unique,
    ''');
          }
          if (autoIncrementPrimary == true) {
            metaCode.writeln('''
           autoIncrementPrimary: $autoIncrementPrimary,
    ''');
          }
          if (notNull == true) {
            metaCode.writeln('''
           notNull: $notNull,
    ''');
          }
          if (defaultValue != null) {
            if (field.type.isDartCoreString) {
              metaCode.writeln('''
           defaultValue: '$defaultValue',
    ''');
            } else {
              metaCode.writeln('''
           defaultValue: $defaultValue,
    ''');
            }
          }
          if (hasWrite) {
            metaCode.writeln('''
          write: (entity) => entity.write$fieldNameCamel(),
    ''');
          } else if (jsonEncoded) {
            var typeName = isDefaultType ? alias : fieldName;
            metaCode.writeln('''
          write: (entity) {
    ''');
            var isDartCoreList = isDefaultType ? false : isList;
            if (isDefaultType) {
              final finder = PropertyFinder(alias!);
              classElement.accept(finder);
              final property = finder.foundProperty!;
              isDartCoreList = property.type.isDartCoreList;
              jsonEncodedType =
                  property.type.getDisplayString(withNullability: false);
            }
            final isNotNull = isDefaultType ? aliasNotNull : notNull;

            if (isDartCoreList) {
              metaCode.writeln('''
            final map = entity.$typeName${isNotNull ? '' : '?'}.map((p) => p.toMap()).toList();
    ''');
            } else {
              var typeName = isDefaultType ? alias : fieldName;
              metaCode.writeln('''
            if(entity.$typeName == null){
                return null;
            }
            final map = entity.$typeName?.${writeFn ?? 'toMap'}();
    ''');
            }
            metaCode.writeln('''
            return jsonEncode(map);
            },
    ''');
          } else {
            metaCode.writeln('''
          write: (entity) => entity.$fieldName,
    ''');
          }
          if (hasRead || jsonEncoded) {
            if (jsonEncoded) {
              if (alias != null) {
                if (aliasNotNull) {
                  copyWithPropsList.writeln('$jsonEncodedType? $alias,');
                  copyWithList.writeln('$alias: $alias ?? this.$alias,');
                } else {
                  copyWithPropsList
                      .writeln('CopyWith<$jsonEncodedType?>? $alias,');
                  copyWithList.writeln(
                      '$alias: $alias != null ? $alias.value : this.$alias,');
                }
                if (extraFields.containsKey(alias)) {
                  extraFields.remove(alias);
                }
              }
              metaCode.writeln('''
          read: (json, entity, value){
            if ('null' == value){
              return entity.read$fieldNameCamel(json, null);
            }
            return entity.read$fieldNameCamel(json, value);
          },
        );
    ''');
            } else {
              metaCode.writeln('''
          read: (json, entity, value) => entity.read$fieldNameCamel(json, value),
        );
    ''');
            }
          } else if (notNull) {
            metaCode.writeln('''
          read: (json, entity, value) => entity.copyWith($fieldName: value, json: json),
        );
    ''');
          } else {
            metaCode.writeln('''
          read: (json, entity, value) => entity.copyWith($fieldName: CopyWith(value), json: json),
        );
    ''');
          }
          if (notNull) {
            copyWithPropsList.writeln('$fieldType? $fieldName,');
            copyWithList.writeln('$fieldName: $fieldName ?? this.$fieldName,');
          } else {
            copyWithPropsList.writeln('CopyWith<$fieldType?>? $fieldName,');
            copyWithList.writeln(
                '$fieldName: $fieldName != null ? $fieldName.value : this.$fieldName,');
          }

          if (extraFields.containsKey(fieldName)) {
            extraFields.remove(fieldName);
          }
        }
      } else if (const TypeChecker.fromRuntime(NullableProp)
          .hasAnnotationOfExact(field)) {
        final fieldName = field.name;
        final fieldType = field.type.getDisplayString(withNullability: false);
        final fieldTypeFull =
            field.type.getDisplayString(withNullability: true);
        extraFields[fieldName] = _ExtraField(
          type: fieldType,
          notNull: false,
          typeFull: fieldTypeFull,
        );
      } else if (const TypeChecker.fromRuntime(CopyableProp)
          .hasAnnotationOfExact(field)) {
        final fieldName = field.name;
        final fieldType = field.type.getDisplayString(withNullability: false);
        final fieldTypeFull =
            field.type.getDisplayString(withNullability: true);
        extraFields[fieldName] = _ExtraField(
          type: fieldType,
          notNull: field.type.nullabilitySuffix == NullabilitySuffix.none,
          typeFull: fieldTypeFull,
        );
      }
    }
    for (final fieldName in extraFields.keys) {
      final extraField = extraFields[fieldName]!;

      propsList.writeln('$fieldName,');
      getList.writeln('${extraField.typeFull} get $fieldName;');
      if (extraField.notNull) {
        copyWithPropsList.writeln('${extraField.type}? $fieldName,');
        copyWithList.writeln('$fieldName: $fieldName ?? this.$fieldName,');
      } else {
        copyWithPropsList.writeln('CopyWith<${extraField.type}?>? $fieldName,');
        copyWithList.writeln(
            '$fieldName: $fieldName != null ? $fieldName.value : this.$fieldName,');
      }
    }
    mixinCode.writeln(getList);
    mixinCode.writeln('''

      @override
      List<Object?> get props => [
        ...super.props,
      ''');
    mixinCode.writeln('''
      $propsList
      ];''');

    metaCode.writeln('''
      @override
      Iterable<ColumnDefinition<$className, dynamic>> get columns => [
      id,
      createdAt,
      updatedAt,
      ''');

    metaCode.writeln('''
      $columnsList
      ];''');

    mixinCode.writeln('''
      @override
      $className copyWith({
        String? id,
        DateTime? createdAt,
        DateTime? updatedAt,
        $copyWithPropsList
        Map<String, dynamic>? json,
      }){
        return $className(
          id: id ?? this.id,
          createdAt: createdAt ?? this.createdAt,
          updatedAt: updatedAt ?? this.updatedAt,
          $copyWithList
        );
      }''');
    mixinCode.writeln('}');
    metaCode.writeln('}');
    mixinCode.write(metaCode.toString());
    return mixinCode.toString();
  }

  // Helper function to convert the first letter of a string to uppercase
  String _toUpperCamelCase(String input) {
    return input[0].toUpperCase() + input.substring(1);
  }

  String convertClassNameToSnakeCase(String className) {
    final buffer = StringBuffer();
    bool isFirstLetter = true;

    for (final char in className.runes) {
      if (isFirstLetter) {
        buffer.write(String.fromCharCode(char).toLowerCase());
        isFirstLetter = false;
      } else if (String.fromCharCode(char).toUpperCase() ==
          String.fromCharCode(char)) {
        buffer.write('_${String.fromCharCode(char).toLowerCase()}');
      } else {
        buffer.write(String.fromCharCode(char));
      }
    }

    return buffer.toString();
  }
}
