# Search and navigation

Press **⌘K** to search the account's local index. Search options can enable itslearning resource search or background indexing of archived courses. Search results keep keyboard selection by ID. **Back to search** (⌘⌥[) restores the query, filters, results and selected result after opening a match.

## Data flow

- App refreshes feed course, task, plan, folder, announcement and calendar metadata into the account's SQLite FTS5 index. A background crawl discovers nested folders and saves a per-course folder queue. Lists that finish successfully replace only their own collection. Partial reads merge records and contexts. The default crawl covers active courses and a recent window of conversations and events.
- The index lives beside the account snapshots, using the existing institution-and-person storage key. Folder, plan, and online resource records share a material key derived from course, element type and element ID. Contexts from multiple sources remain available in the result preview. Plan elements are adapted through the existing `Resource(planElement:)` mapping, so equivalent folder records only merge when their element types agree.
- A serial background worker extracts text from PDFs and UTF-8 text or Markdown already saved in Laer. It records a row per PDF page and uses the opaque download revision to avoid repeating work. It never downloads content for indexing. Results open the matching revision and PDF page, with a highlight when the original page contains the matched text. Plain-text results open the saved file.
- **Recognize text in scans and images** in Search options enables local Apple Vision OCR for saved PDFs, PNG and JPEG. PDFKit checks the embedded PDF text first. Pages with fewer than 24 letters can fall back to Vision, with Danish and English selected when the installed recognizer supports them. OCR rasterizes one page at a time and processes at most two scans per batch. Each batch commits its text and next-page checkpoint together. Turning the option off or entering Low Power Mode pauses new work at a page boundary. Resuming picks up at the last committed page, including after restarting Laer. Existing OCR matches stay searchable while paused and are marked as potentially inaccurate. PDF matches open on the matching page. [Apple Vision text recognition](https://developer.apple.com/documentation/vision/vnrecognizetextrequest)
- Local queries use bound SQLite parameters and a restricted FTS5 phrase and prefix syntax. Local matching and online requests run independently. Online search sends the query to the selected institution only after opt-in. It uses the documented single-course resource route sequentially for up to 12 courses, reports partial coverage and appends online matches by stable ID. The route has no documented paging parameters. [itslearning resource search contract](https://www.itslearning.com/restapi/help/Api/GET-restapi-personal-courses-locationId-resources-search-v1_locationType_searchText)

## Privacy and migration

- Search text, excerpts and navigation state stay on the device when online search is off. Return-to-search state lives in the window and clears at account change. In-flight results are tied to the originating account store. This change adds no query logging or telemetry.
- A successful complete course list removes index rows with a known, now-absent course ID. A partial list or an isolated endpoint refusal cannot establish that access to the course was revoked. Offline results use last-known access. A saved document whose download revision changes or disappears is excluded from search immediately. Removing a saved file also removes its extracted records.
- The old JSON search cache is superseded by an account-scoped SQLite database. The app seeds course and task metadata from cached collections and indexes saved PDFs/text and refreshed metadata as it runs. A user can rebuild the index from Search options. The rebuild preserves original files and source snapshots. SQLite schema updates run in a transaction.
- Extraction ignores unsupported formats and files larger than 24 MiB. It indexes up to 400 PDF pages, 24,000 embedded characters per page and 400,000 embedded characters per document. OCR adds up to 8,000 recognized characters per page and uses rasters up to 1,536 pixels on the longest side. ImageIO checks PNG/JPEG format and rejects standalone images above 64 megapixels before rasterization. Locked PDFs and pages without usable embedded or recognized text have no full-text results. Search previews display plain text and never execute document markup.

## Requirement coverage

| Area | Status |
| --- | --- |
| Account-scoped disk index, stable identities, independent refresh groups, preserved partial data | Implemented with storage and API regression tests |
| Offline search, quoted phrases, word prefixes, accent folding, course/type/format filters, ranked results | Implemented with engine and palette tests |
| Opt-in institution search, local-first results, cursor and selection by object ID | Implemented with a mocked route and palette test. Live institutional permission and throttling behavior need a real account verification. |
| Course folders and archives | Folder-level progress is saved. An individual listing beyond the existing 50-page API safety limit stays partial. Continuation within that listing remains. |
| PDF and UTF-8 full text, page anchors and highlights, download revision handling | Implemented. Opt-in Vision OCR covers scanned PDF pages and saved PNG/JPEG images, with persistent checkpoints and PDF page-level results. Region highlights on scans, DOCX/PPTX and spreadsheets remain. |
| Plans, tasks, materials, announcements, messages and events | Plans and saved PDF pages have direct UI coverage. Messages open the matching conversation from the recent indexed window. Broader message coverage and precise message anchors remain. |
| Result actions and navigation | Context and excerpt preview, expandable page matches, more results and return-to-search are implemented. General forward history, offline bulk actions, safe sharing links, bookmarks and saved searches remain. |
| Relevance and commands | Exact titles, phrases and prefixes are implemented. Typo correction, natural-language filters, optional local embeddings and a unified command registry remain. |
| Platform quality | GitHub Actions runs on macOS 26 with Xcode 26. The deployment target remains macOS 14. Interactive VoiceOver, macOS 14, and representative student testing remain. |

## Reproduce

```sh
swift test --package-path Packages/LaerCore
xcodebuild -project Laer.xcodeproj -scheme Laer -destination 'platform=macOS,arch=arm64' \
  -only-testing:LaerMacUITests -parallel-testing-enabled NO test
LAER_SEARCH_BENCHMARK=1 swift test --package-path Packages/LaerCore --filter measuresMetadataAndDocumentQueries
```

The synthetic benchmark inserts 50,000 metadata records and 5,000 one-page text records. It reports index size, ingestion time, one first query on a fresh connection, warmed engine p95 by query type, and top-three relevance for 80 preselected exact identifier queries. It keeps PDF parsing, UI repaint and network time out of these measurements. A fresh connection still benefits from the OS file cache. The app UI latency target and OCR memory and energy remain to be measured.
