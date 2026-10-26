class RelationalValueField {
  const RelationalValueField(this.path, this.kind, {this.type = '', this.text = '', this.number = 0, this.real = 0});
  final String path;
  final String kind;
  final String type;
  final String text;
  final int number;
  final double real;

  List<Object?> values(String version) => [version, path, kind, type, text, number, real, null];
}

// Matches the native relational codec's map/list/scalar representation. There
// is no JSON document or opaque serialized configuration in these rows.
List<RelationalValueField> encodeRelationalValues(Map<String, dynamic> value) {
  final fields = <RelationalValueField>[];
  void visit(Object? value, String path, int depth, {bool boxed = false}) {
    if (depth > 128 || fields.length > 100000) throw StateError('Слишком сложные настройки');
    var fieldPath = path;
    if (value == null) {
      fields.add(RelationalValueField(fieldPath, 'nil'));
      return;
    }
    final type = switch (value) {
      bool() => ':bool',
      String() => ':string',
      int() => ':int64',
      double() => ':float64',
      Map() => 'map[:string]interface {}',
      List() => '[]interface {}',
      _ => throw StateError('Неподдерживаемый тип настройки: ${value.runtimeType}'),
    };
    if (boxed) {
      fields.add(RelationalValueField(fieldPath, 'interface', type: type));
      fieldPath = '$fieldPath/value';
    }
    switch (value) {
      case bool():
        fields.add(RelationalValueField(fieldPath, 'bool', number: value ? 1 : 0));
      case String():
        fields.add(RelationalValueField(fieldPath, 'string', text: value));
      case int():
        fields.add(RelationalValueField(fieldPath, 'int', number: value));
      case double():
        if (!value.isFinite) throw StateError('Некорректное числовое значение настройки');
        fields.add(RelationalValueField(fieldPath, 'float', real: value));
      case Map():
        final keys = value.keys.cast<String>().toList()..sort();
        fields.add(RelationalValueField(fieldPath, 'map', number: keys.length));
        for (var index = 0; index < keys.length; index++) {
          fields.add(RelationalValueField('$fieldPath/$index/key', 'string', text: keys[index]));
          visit(value[keys[index]], '$fieldPath/$index/value', depth + 1, boxed: true);
        }
      case List():
        fields.add(RelationalValueField(fieldPath, 'list', number: value.length));
        for (var index = 0; index < value.length; index++) {
          visit(value[index], '$fieldPath/$index', depth + 1, boxed: true);
        }
    }
  }

  visit(value, '', 0);
  return fields;
}
