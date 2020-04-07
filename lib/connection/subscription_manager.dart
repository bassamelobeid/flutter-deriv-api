import 'dart:async';
import 'package:meta/meta.dart';

import 'package:flutter_deriv_api/api/request.dart';
import 'package:flutter_deriv_api/api/response.dart';
import 'package:flutter_deriv_api/api/api.helper.dart';
import 'package:flutter_deriv_api/api/forget_send.dart';
import 'package:flutter_deriv_api/api/forget_receive.dart';
import 'package:flutter_deriv_api/api/forget_all_send.dart';
import 'package:flutter_deriv_api/api/forget_all_receive.dart';
import 'package:flutter_deriv_api/connection/subscription_stream.dart';
import 'package:flutter_deriv_api/connection/connection_websocket.dart';
import 'package:flutter_deriv_api/connection/pending_subscribe_request.dart';

/// Subscription manager class
class SubscriptionManager {
  /// Singleton instance
  factory SubscriptionManager({@required BinaryApi api}) {
    _instance._api = api;

    return _instance;
  }

  SubscriptionManager._();

  static final SubscriptionManager _instance = SubscriptionManager._();

  BinaryApi _api;

  /// Any subscription requests that are currently in-flight
  final Map<int, PendingSubscribeRequest<Response>> _pendingRequests =
      <int, PendingSubscribeRequest<Response>>{};

  /// Add a request to pending request queue
  void add({
    int requestId,
    Map<String, dynamic> request,
    Completer<Response> response,
  }) =>
      _pendingRequests[requestId] = PendingSubscribeRequest<Response>(
        request: request,
        response: response,
      );

  /// Indicates that pending request exists or not
  bool contains(int requestId) => _pendingRequests.containsKey(requestId);

  /// Get request response
  Completer<Response> getResponse(int requestId) =>
      _pendingRequests[requestId].response;

  /// Get subscription id
  String getSubscriptionId(int requestId) =>
      _pendingRequests[requestId]?.subscriptionId;

  /// Get subscription stream
  SubscriptionStream<Response> getSubscriptionStream(int requestId) =>
      _pendingRequests[requestId]?.subscriptionStream;

  /// Set subscription id
  void setSubscriptionId({
    int requestId,
    String subscriptionId,
  }) =>
      _pendingRequests[requestId].subscriptionId = subscriptionId;

  /// Set subscription stream
  void setSubscriptionStream({
    int requestId,
    SubscriptionStream<Response> subscriptionStream,
  }) =>
      _pendingRequests[requestId].subscriptionStream = subscriptionStream;

  /// Handle stream response
  void handleStreamResponse({
    int requestId,
    Map<String, dynamic> response,
  }) {
    print('completing request for $requestId.');

    final Response resultResponse = getResponseByMsgType(response);
    final Completer<Response> requestCompleter = getResponse(requestId);

    if (!requestCompleter.isCompleted) {
      requestCompleter.complete(resultResponse);
    }

    // Adds the subscription id to the pendingRequest object for further references.
    if (response.containsKey('subscription')) {
      setSubscriptionId(
        requestId: requestId,
        subscriptionId: response['subscription']['id'],
      );
    }

    // Broadcasts the new message into the stream.
    getSubscriptionStream(requestId).add(resultResponse);

    print('response added to stream.');
  }

  /// Calls the API method with subscribe set to '1' and return the stream
  /// to caller for responses
  Stream<Response> subscribe(Request request) {
    // TODO(hamed): we should check request duplication before another api call

    final SubscriptionStream<Response> subscriptionStream =
        SubscriptionStream<Response>();

    _api.call(request, subscribeCall: true);

    _pendingRequests[request.reqId].subscriptionStream = subscriptionStream;

    return subscriptionStream.stream;
  }

  /// unsubscribe with a specific [subscriptionId]
  Future<ForgetResponse> unsubscribe(
    String subscriptionId, {
    bool shouldForced = false,
  }) async {
    final int requestId = _pendingRequests.keys
        .singleWhere((int id) => getSubscriptionId(id) == subscriptionId);

    if (getSubscriptionStream(requestId).hasListener && !shouldForced) {
      throw Exception('The stream has listener');
    }

    // Send forget request
    final Response response = await _api.call(
      ForgetRequest(forget: getSubscriptionId(requestId)),
    );

    if (response.error == null) {
      await _removePendingRequest(requestId);
    }

    return response;
  }

  /// Unsubscribe to multiple [method]s all at once
  Future<dynamic> unsubscribeAll(
    String method, {
    bool shouldForced = false,
  }) async {
    final List<int> requestIds = _pendingRequests.keys.where(
      (int id) =>
          _pendingRequests[id].method == method &&
          _pendingRequests[id].isSubscribed,
    );

    final ForgetAllResponse response =
        await BinaryApi().call(ForgetAllRequest(forgetAll: method));

    if (response.error == null) {
      for (int id in requestIds) {
        await _removePendingRequest(id);
      }
    }

    return response;
  }

  Future<void> _removePendingRequest(int requestId) async {
    await getSubscriptionStream(requestId).closeStream();
    _pendingRequests.remove(requestId);
  }
}
