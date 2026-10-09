import 'package:becklink_flutter/becklink_flutter.dart';
import 'package:flutter/material.dart';

/// Runs [action] and shows the message it returns, or why it failed, in a
/// snack bar.
///
/// SDK failures carry a stable code and a message that says how to fix
/// them; an [ArgumentError] means the input broke a documented rule; a
/// [FormatException] is JSON or a URL typed on this screen; a [StateError]
/// or [UnsupportedError] comes from the debug helpers.
Future<void> runWithFeedback(
  BuildContext context,
  Future<String> Function() action,
) async {
  final messenger = ScaffoldMessenger.of(context);
  String message;
  try {
    message = await action();
  } on BeckLinkException catch (error) {
    message = describeBeckLinkException(error);
  } on ArgumentError catch (error) {
    message = 'Not accepted: ${error.message}';
  } on FormatException catch (error) {
    message = 'Not valid: ${error.message}';
  } on StateError catch (error) {
    message = error.message;
  } on UnsupportedError catch (error) {
    message = error.message ?? 'Not supported in this build.';
  }
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

/// `code: message (request …)`, the form the Beck Link docs search for.
String describeBeckLinkException(BeckLinkException error) {
  final requestId = error.requestId;
  final status = error.statusCode;
  return '${error.code.wireValue}: ${error.message}'
      '${status == null ? '' : ' (HTTP $status)'}'
      '${requestId == null ? '' : ' (request $requestId)'}';
}
