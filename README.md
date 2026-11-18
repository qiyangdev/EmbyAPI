# EmbyAPI

EmbyAPI is an unofficial Swift package for the Emby Server REST API. It provides typed operations for signing in, browsing libraries, querying filter options, fetching media and images, and reporting playback. The client is generated at build time from a pinned OpenAPI snapshot.

## Installation

Add `https://github.com/qiyangdev/EmbyAPI.git` as a package dependency in Xcode and link the `EmbyAPI` product. In a Swift package manifest, use:

```swift
.package(url: "https://github.com/qiyangdev/EmbyAPI.git", from: "0.2.0")
```

## Usage

Pass the complete API base URL, including any reverse proxy prefix or `/emby` segment your server uses. Supply a stable device ID. Store and restore the returned session credentials in the calling app.

```swift
import EmbyAPI

let identity = EmbyClient.Identity(
    client: "My Player",
    device: deviceName,
    deviceID: deviceID,
    version: appVersion
)
let client = try EmbyClient(serverURL: apiBaseURL, identity: identity)
let session = try await client.signIn(username: username, password: password)
let authenticated = try EmbyClient(serverURL: apiBaseURL, identity: identity, session: session)
let libraries = try await authenticated.api.getUsersByUseridViews(
    path: .init(UserId: session.userID)
).ok.body.json
```

## Development

Run `swift test` from the repository root. The tests use an in-memory transport.

The OpenAPI snapshot is a subset of the [Emby SDK 4.10.2.0 specification](https://github.com/MediaBrowser/Emby.SDK/blob/45e73012eddf985dcfe878ca031b500085e16496/Resources/OpenApi/openapi_v3.json). Run `python3 Tools/update-openapi.py` to regenerate it from the pinned revision. The script selects the supported operations and applies the response schema adjustments used by Swift OpenAPI Generator. To compare against a running server, fetch its [OpenAPI document](https://dev.emby.media/reference/RestAPI/OpenApiService/getOpenapi.html) and pass the downloaded file to the script with `--source`.

## License

See [MPL 2.0](LICENSE.md) for the Swift source code. The OpenAPI snapshot is derived from Emby's SDK specification linked above.
