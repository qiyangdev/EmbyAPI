//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

// SPDX-License-Identifier: MPL-2.0

import Foundation
import HTTPTypes
import OpenAPIRuntime
import OpenAPIURLSession

/// Configures the generated API client for an Emby server.
public struct EmbyClient: Sendable {

    public struct Identity: Sendable {

        public let client: String
        public let device: String
        public let deviceID: String
        public let version: String

        public init(client: String, device: String, deviceID: String, version: String) {
            self.client = client
            self.device = device
            self.deviceID = deviceID
            self.version = version
        }
    }

    /// The app owns persistence and supplies a token when restoring a session.
    public struct Session: Sendable {

        public let userID: String
        public let accessToken: String
        public let serverID: String?

        public init(userID: String, accessToken: String, serverID: String? = nil) {
            self.userID = userID
            self.accessToken = accessToken
            self.serverID = serverID
        }
    }

    public enum Error: Swift.Error, Equatable {

        case invalidServerURL
        case invalidAuthenticationResponse
        case httpStatus(Int)
    }

    public let serverURL: URL
    private let identity: Identity
    private let transport: any ClientTransport
    private let session: Session?

    /// Applies the same authentication as the generated client to a Foundation request.
    public func authenticate(_ request: inout URLRequest) {
        request.setValue(
            EmbyRequestMiddleware.authorizationValue(identity: identity, session: session),
            forHTTPHeaderField: "X-Emby-Authorization"
        )
        request.setValue(session?.accessToken, forHTTPHeaderField: "X-Emby-Token")
    }

    /// Pass the API base URL, including any reverse proxy prefix and the `/emby`
    /// segment if required by the server, for example `https://host/media/emby`.
    public init(
        serverURL: URL,
        identity: Identity,
        session: Session? = nil,
        transport: any ClientTransport? = nil
    ) throws {
        guard var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: true),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil
        else { throw Error.invalidServerURL }

        while components.percentEncodedPath.hasSuffix("/") {
            components.percentEncodedPath.removeLast()
        }
        guard let normalizedURL = components.url else { throw Error.invalidServerURL }

        self.serverURL = normalizedURL
        self.identity = identity
        self.session = session
        self.transport = transport ?? Self.defaultTransport
    }

    /// Typed operations and response status cases generated from Emby's OpenAPI document.
    public var api: Client {
        Client(
            serverURL: serverURL,
            configuration: .init(dateTranscoder: EmbyDateTranscoder()),
            transport: transport,
            middlewares: [EmbyRequestMiddleware(identity: identity, session: session)]
        )
    }

    public func signIn(username: String, password: String) async throws -> Session {
        let response = try await api.postUsersAuthenticatebyname(
            body: .json(.init(Pw: password, Username: username))
        )
        switch response {
        case let .ok(output):
            let result = try output.body.json
            guard let userID = result.User?.Id,
                  !userID.isEmpty,
                  let token = result.AccessToken,
                  !token.isEmpty
            else { throw Error.invalidAuthenticationResponse }

            return Session(userID: userID, accessToken: token, serverID: result.ServerId)

        case .badRequest: throw Error.httpStatus(400)

        case .unauthorized: throw Error.httpStatus(401)

        case .forbidden: throw Error.httpStatus(403)

        case .notFound: throw Error.httpStatus(404)

        case .internalServerError: throw Error.httpStatus(500)

        case let .undocumented(status, _): throw Error.httpStatus(status)
        }
    }

    private static let defaultTransport = URLSessionTransport(configuration: .init(
        session: URLSession(configuration: .default, delegate: EmbyRedirectDelegate(), delegateQueue: nil)
    ))
}

private struct EmbyRequestMiddleware: ClientMiddleware {

    static let authorization = HTTPField.Name("X-Emby-Authorization")!
    static let token = HTTPField.Name("X-Emby-Token")!

    let identity: EmbyClient.Identity
    let session: EmbyClient.Session?

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var request = request
        if operationID == Operations.getVideosByIdStream.id,
           let encodedRange = request.headerFields[.range] {
            // The generated header value is URI-encoded. HTTP expects a literal bytes range.
            request.headerFields[.range] = encodedRange.removingPercentEncoding ?? encodedRange
        }
        let publicOperation = [
            Operations.getSystemInfoPublic.id,
            Operations.getUsersPublic.id,
            Operations.postUsersAuthenticatebyname.id,
        ].contains(operationID)
        let credentials = publicOperation ? nil : session
        request.headerFields[Self.token] = credentials?.accessToken
        request.headerFields[Self.authorization] = Self.authorizationValue(identity: identity, session: credentials)
        return try await next(request, body, baseURL)
    }

    static func authorizationValue(identity: EmbyClient.Identity, session: EmbyClient.Session?) -> String {
        var fields = [
            ("Client", identity.client),
            ("Device", identity.device),
            ("DeviceId", identity.deviceID),
            ("Version", identity.version),
        ]
        if let session {
            fields.append(("UserId", session.userID))
        }
        return "Emby " + fields
            .map { key, value in "\(key)=\"\(Self.encode(value))\"" }
            .joined(separator: ", ")
    }

    private static func encode(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 -._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}

private struct EmbyDateTranscoder: DateTranscoder {

    func encode(_ date: Date) throws -> String {
        date.formatted(.iso8601)
    }

    func decode(_ dateString: String) throws -> Date {
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(dateString) {
            return date
        }
        return try Date.ISO8601FormatStyle().parse(dateString)
    }
}

private final class EmbyRedirectDelegate: NSObject, URLSessionTaskDelegate {

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let original = response.url,
              let destination = request.url,
              original.scheme?.lowercased() == destination.scheme?.lowercased(),
              original.host?.lowercased() == destination.host?.lowercased(),
              Self.port(of: original) == Self.port(of: destination)
        else {
            completionHandler(nil)
            return
        }

        completionHandler(request)
    }

    private static func port(of url: URL) -> Int {
        url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
    }
}
