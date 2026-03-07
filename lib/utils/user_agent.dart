/// Central User-Agent string for all outgoing HTTP requests.
///
/// Podcast hosts, CDNs, and analytics services (OP3, Podtrac, Chartable, etc.)
/// use User-Agent to attribute listens and subscriber counts to specific apps.
/// Keeping this consistent across RSS fetches, audio streams, and API calls
/// ensures YourPods shows up correctly in podcast statistics.
const String yourPodsUserAgent = 'YourPods/1.3.1 (+https://yourpods.app)';

/// Convenience helper – merges the User-Agent into an existing header map
/// (or creates a new one) without overwriting other headers.
Map<String, String> withUserAgent([Map<String, String>? headers]) {
  return {
    if (headers != null) ...headers,
    'User-Agent': yourPodsUserAgent,
  };
}
