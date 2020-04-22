import 'package:flutter_deriv_api/api/models/base_model.dart';

/// Duration class
class DurationModel extends BaseModel {
  /// Class constructor
  DurationModel({
    this.displayName,
    this.max,
    this.min,
    this.name,
  });

  /// Creates instance from json
  factory DurationModel.fromJson(Map<String, dynamic> json) => DurationModel(
        displayName: json['display_name'],
        max: json['max'],
        min: json['min'],
        name: json['name'],
      );

  /// Translated duration type name.
  final String displayName;

  /// Maximum allowed duration for this type.
  final int max;

  /// Minimum allowed duration for this type.
  final int min;

  /// Duration type name.
  final String name;

  /// Creates copy of instance with given parameters
  DurationModel copyWith({
    String displayName,
    int max,
    int min,
    String name,
  }) =>
      DurationModel(
        displayName: displayName ?? this.displayName,
        max: max ?? this.max,
        min: min ?? this.min,
        name: name ?? this.name,
      );
}
