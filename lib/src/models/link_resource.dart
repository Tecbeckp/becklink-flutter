import 'package:meta/meta.dart';

import '../json/json_reader.dart';

/// The item a URL-template link points at, such as challenge `4521`.
///
/// A project can share every item of its app through one URL pattern, for
/// example `https://getshouri.becklinks.com/c/{id}`, without creating a link
/// per item. When such a URL opens the app, [LinkEvent.resource] names the
/// item: [type] is the resource type's key (`challenge`) and [id] the value
/// taken from the URL. Fetch the item through your own API with it; nothing
/// but the id travels in the URL.
///
/// Treat [id] as untrusted input, like the rest of a link: anyone can craft
/// a URL. Beck Link only checks that it fits the format the template allows
/// (for example digits), not that the item exists or may be seen.
@immutable
final class LinkResource {
  /// Creates a resource reference.
  const LinkResource({required this.type, required this.id});

  /// Reads the SDK API JSON form (`resource` of a `link_event`).
  ///
  /// Throws a [FormatException] when `type` or `id` is missing or not a
  /// string.
  factory LinkResource.fromJson(Map<String, Object?> json) =>
      readLinkResource(JsonReader(json));

  /// The resource type's key, such as `challenge` (lower-case letters,
  /// digits and `_`).
  final String type;

  /// The item's ID as it appears in the URL, already percent-decoded. At most
  /// 128 characters.
  final String id;

  /// The SDK API JSON form.
  Map<String, Object?> toJson() => <String, Object?>{'type': type, 'id': id};

  @override
  bool operator ==(Object other) =>
      other is LinkResource && other.type == type && other.id == id;

  @override
  int get hashCode => Object.hash(type, id);

  // The ID can be user content; logs get the type only.
  @override
  String toString() => 'LinkResource(type: $type)';
}

/// Reads a [LinkResource] from [reader]. Internal to the SDK.
LinkResource readLinkResource(JsonReader reader) =>
    LinkResource(type: reader.string('type'), id: reader.string('id'));
