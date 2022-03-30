import 'package:flutter_deriv_api/api/common/exceptions/common_exception.dart';
import 'package:flutter_deriv_api/api/models/base_exception_model.dart';

/// Exception class for Landing company
class LandingCompanyException extends CommonException {
  /// Initializes
  LandingCompanyException({
    BaseExceptionModel? baseExceptionModel,
  }) : super(baseExceptionModel: baseExceptionModel);
}
