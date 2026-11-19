//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

// SPDX-License-Identifier: MPL-2.0

import EmbyAPI
import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing

struct EmbyAPITests {

    @Test
    func `reads the server login notice without a user session`() async throws {
        let client = try makeClient { request, _, _ in
            #expect(request.method == .get)
            #expect(request.path == "/Branding/Configuration")
            #expect(request.headerFields[token] == nil)
            return json(#"{"LoginDisclaimer":"Welcome.<br/>Please sign in."}"#)
        }

        let branding = try await client.api.getBrandingConfiguration().ok.body.json
        #expect(branding.LoginDisclaimer == "Welcome.<br/>Please sign in.")
    }

    @Test
    func `signs in with emby authorization and JSON credentials`() async throws {
        let client = try makeClient(session: session) { request, body, baseURL in
            #expect(baseURL.absoluteString == "https://example.com/proxy/emby")
            #expect(request.method == .post)
            #expect(request.path == "/Users/AuthenticateByName")
            #expect(request.headerFields[authorization] ==
                #"Emby Client="SwiftEmby", Device="iPhone Duo", DeviceId="ios-1", Version="1.0""#)
            #expect(request.headerFields[token] == nil)
            #expect(request.headerFields[.contentType] == "application/json; charset=utf-8")

            let data = try await Data(collecting: #require(body), upTo: 4096)
            let credentials = try JSONDecoder().decode([String: String].self, from: data)
            #expect(credentials == ["Username": "tester", "Pw": " abc "])

            return json(#"{"AccessToken":"new-token","ServerId":"server","User":{"Id":"12","Name":"Tester"}}"#)
        }

        let result = try await client.signIn(username: "tester", password: " abc ")
        #expect(result.accessToken == "new-token")
        #expect(result.userID == "12")
        #expect(result.serverID == "server")
    }

    @Test
    func `reports authentication failure`() async throws {
        let client = try makeClient { _, _, _ in (.init(status: .unauthorized), nil) }
        await #expect(throws: EmbyClient.Error.httpStatus(401)) {
            try await client.signIn(username: "tester", password: "wrong")
        }
    }

    @Test
    func `browses with user token and decodes item data`() async throws {
        let client = try makeClient(session: session) { request, _, _ in
            #expect(request.method == .get)
            #expect(request.headerFields[token] == "old-token")
            #expect(request.headerFields[authorization]?.contains(#"UserId="12""#) == true)

            let path = try #require(request.path)
            let target = try #require(URLComponents(string: path))
            #expect(target.path == "/Users/12/Items")
            #expect(target.queryItems?.contains(.init(name: "ParentId", value: "7")) == true)
            #expect(target.queryItems?.contains(.init(name: "SearchTerm", value: "A+B & 动画")) == true)
            #expect(target.percentEncodedQuery?.contains("A%2BB") == true)
            return json(#"""
            {
              "Items": [{
                "Id": "19", "Name": "Short Film", "Type": "Movie",
                "DateCreated": "2026-10-01T09:59:15.1234567Z",
                "ImageTags": { "Primary": "poster" },
                "UserData": { "PlaybackPositionTicks": 300000000 }
              }],
              "TotalRecordCount": 1
            }
            """#)
        }

        let response = try await client.api.getUsersByUseridItems(
            path: .init(UserId: "12"),
            query: .init(SearchTerm: "A+B & 动画", ParentId: "7")
        )
        let page = try response.ok.body.json
        #expect(page.TotalRecordCount == 1)
        let item = try #require(page.Items?.first)
        #expect(item.Id == "19")
        #expect(item.DateCreated != nil)
        #expect(item.UserData?.PlaybackPositionTicks == 300_000_000)
    }

    @Test
    func `decodes playback info and accepts empty progress response`() async throws {
        let client = try makeClient(session: session) { request, body, _ in
            let data = try await Data(collecting: #require(body), upTo: 4096)
            let jsonBody = try JSONDecoder().decode([String: String].self, from: data)
            if request.path == "/Items/19/PlaybackInfo" {
                #expect(jsonBody == ["UserId": "12"])
                return json(#"""
                {
                  "PlaySessionId": "play-1",
                  "MediaSources": [{
                    "Id": "source-1", "Container": "mp4", "SupportsDirectPlay": true,
                    "RequiredHttpHeaders": {"Referer": "https://example.com"}
                  }]
                }
                """#)
            }
            #expect(request.path == "/Sessions/Playing/Progress")
            #expect(jsonBody == ["ItemId": "19", "MediaSourceId": "source-1", "PlaySessionId": "play-1"])
            return (.init(status: .noContent), nil)
        }

        let info = try await client.api
            .postItemsByIdPlaybackinfo(
                path: .init(Id: "19"),
                body: .json(.init(UserId: "12"))
            )
            .ok
            .body
            .json
        let source = try #require(info.MediaSources?.first)
        #expect(source.SupportsDirectPlay == true)
        #expect(info.PlaySessionId == "play-1")
        let progress = try await client.api.postSessionsPlayingProgress(body: .json(
            .init(ItemId: "19", MediaSourceId: source.Id, PlaySessionId: info.PlaySessionId)
        ))
        _ = try progress.noContent
    }

    @Test
    func `catalog preserves unknown track types and explicit nulls`() async throws {
        let client = try makeClient(session: session) { request, _, _ in
            let path = try #require(request.path)
            let url = try #require(URLComponents(string: path))
            #expect(url.path == "/Items")
            #expect(url.queryItems?.contains(.init(name: "UserId", value: "12")) == true)
            #expect(url.queryItems?.contains(.init(name: "StartIndex", value: "20")) == true)
            return json(#"""
            {
              "TotalRecordCount": 23,
              "Items": [{
                "Id": "19",
                "Overview": null,
                "MediaSources": [{"MediaStreams": [{"Type": "Attachment"}, {"Type": "FutureType"}]}]
              }]
            }
            """#)
        }

        let page = try await client.api.getItems(query: .init(StartIndex: 20, UserId: "12")).ok.body.json
        let row = try #require(page.Items?.first)
        let data = try JSONEncoder().encode(row)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let sources = try #require(object["MediaSources"] as? [[String: Any]])
        let streams = try #require(sources.first?["MediaStreams"] as? [[String: Any]])
        #expect(page.TotalRecordCount == 23)
        #expect(object["Overview"] is NSNull)
        #expect(streams.compactMap { $0["Type"] as? String } == ["Attachment", "FutureType"])
    }

    @Test
    func `lists filter options in the user and library scope`() async throws {
        let client = try makeClient(session: session) { request, _, _ in
            #expect(request.method == .get)
            #expect(request.headerFields[token] == "old-token")

            let path = try #require(request.path)
            let url = try #require(URLComponents(string: path))
            for queryItem in [
                URLQueryItem(name: "UserId", value: "12"),
                URLQueryItem(name: "ParentId", value: "7"),
                URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series"),
                URLQueryItem(name: "Recursive", value: "true"),
            ] {
                #expect(url.queryItems?.contains(queryItem) == true)
            }

            let names = ["/Genres": "Animation", "/OfficialRatings": "PG", "/Tags": "Family", "/Years": "2026"]
            let name = try #require(names[url.path])
            return json(#"{"Items":[{"Name":"\#(name)"}],"TotalRecordCount":1}"#)
        }

        let genres = try await client.api.getGenres(
            query: .init(Recursive: true, ParentId: "7", IncludeItemTypes: "Movie,Series", UserId: "12")
        ).ok.body.json
        let ratings = try await client.api.getOfficialratings(
            query: .init(Recursive: true, ParentId: "7", IncludeItemTypes: "Movie,Series", UserId: "12")
        ).ok.body.json
        let tags = try await client.api.getTags(
            query: .init(Recursive: true, ParentId: "7", IncludeItemTypes: "Movie,Series", UserId: "12")
        ).ok.body.json
        let years = try await client.api.getYears(
            query: .init(Recursive: true, ParentId: "7", IncludeItemTypes: "Movie,Series", UserId: "12")
        ).ok.body.json

        #expect(genres.Items?.first?.Name == "Animation")
        #expect(ratings.Items?.first?.Name == "PG")
        #expect(tags.Items?.first?.Name == "Family")
        #expect(years.Items?.first?.Name == "2026")
    }

    @Test
    func `accepts image response with its actual content type`() async throws {
        let client = try makeClient(session: session) { request, _, _ in
            #expect(request.path?.hasPrefix("/Items/19/Images/Primary?") == true)
            #expect(request.headerFields[token] == "old-token")
            return (.init(status: .ok, headerFields: [.contentType: "image/jpeg"]), HTTPBody([1, 2, 3]))
        }

        let response = try await client.api.getItemsByIdImagesByType(
            path: .init(Id: "19", _Type: .Primary),
            query: .init(MaxWidth: 400)
        )
        let data = try await Data(collecting: response.ok.body.any, upTo: 4096)
        #expect(data == Data([1, 2, 3]))
    }

    @Test
    func `requests video with playback I ds and accepts partial content`() async throws {
        let client = try makeClient(session: session) { request, _, _ in
            let path = try #require(request.path)
            let target = try #require(URLComponents(string: path))
            #expect(target.path == "/Videos/19/stream")
            #expect(target.queryItems?.contains(.init(name: "Static", value: "true")) == true)
            #expect(target.queryItems?.contains(.init(name: "MediaSourceId", value: "source-1")) == true)
            #expect(target.queryItems?.contains(.init(name: "PlaySessionId", value: "play-1")) == true)
            #expect(request.headerFields[.range] == "bytes=0-2")
            return (.init(status: .partialContent, headerFields: [.contentType: "video/mp4"]), HTTPBody([1, 2, 3]))
        }

        let response = try await client.api.getVideosByIdStream(
            path: .init(Id: "19"),
            query: .init(Container: "mp4", Static: true, MediaSourceId: "source-1", PlaySessionId: "play-1"),
            headers: .init(Range: "bytes=0-2")
        )
        let data = try await Data(collecting: response.partialContent.body.any, upTo: 4096)
        #expect(data == Data([1, 2, 3]))
    }
}

private let authorization = HTTPField.Name("X-Emby-Authorization")!
private let token = HTTPField.Name("X-Emby-Token")!
private let session = EmbyClient.Session(userID: "12", accessToken: "old-token")

private struct TestTransport: ClientTransport {

    typealias Handler = @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)

    let handle: Handler

    func send(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        try await handle(request, body, baseURL)
    }
}

private func makeClient(session: EmbyClient.Session? = nil, handle: @escaping TestTransport.Handler) throws -> EmbyClient {
    try EmbyClient(
        serverURL: #require(URL(string: "https://example.com/proxy/emby/")),
        identity: .init(client: "SwiftEmby", device: "iPhone Duo", deviceID: "ios-1", version: "1.0"),
        session: session,
        transport: TestTransport(handle: handle)
    )
}

private func json(_ body: String) -> (HTTPResponse, HTTPBody?) {
    (.init(status: .ok, headerFields: [.contentType: "application/json"]), HTTPBody(body))
}
