import Foundation
import Testing
@testable import Laer

struct NativeFileLinkTests {
    private let element = URL(string: "https://example.itslearning.com/LearningToolElement/ViewLearningToolElement.aspx?LearningToolElementId=42")!

    @Test func findsTheOneSignedFrameForThisElement() {
        let html = """
        <iframe src="https://example.itslearning.com/LoginSSO.aspx?ElementId=7&amp;Signature=abc"></iframe>
        <iframe src='/LoginSSO.aspx?ElementId=42&amp;Signature=def&amp;Return=x'></iframe>
        <iframe src="/LoginSSO.aspx?ElementId=42"></iframe>
        """
        let frame = NativeFileLink.viewerFrame(in: html, base: element, elementId: 42)
        #expect(frame?.absoluteString == "https://example.itslearning.com/LoginSSO.aspx?ElementId=42&Signature=def&Return=x")
    }

    @Test func refusesTwoDifferentFramesForOneElement() {
        let html = """
        <iframe src="/LoginSSO.aspx?ElementId=42&Signature=a"></iframe>
        <iframe src="/LoginSSO.aspx?ElementId=42&Signature=b"></iframe>
        """
        #expect(NativeFileLink.viewerFrame(in: html, base: element, elementId: 42) == nil)
    }

    @Test func usesTheFilePagesOwnDownloadLink() {
        let page = URL(string: "https://resource.itslearning.com/File/View.aspx?LearningObjectId=1&LearningObjectInstanceId=2")!
        let html = #"<a href="/Proxy/DownloadRedirect.ashx?LearningObjectId=9&amp;LearningObjectInstanceId=8">Download</a>"#
        #expect(NativeFileLink.downloadLink(in: html, page: page)?.absoluteString
            == "https://resource.itslearning.com/Proxy/DownloadRedirect.ashx?LearningObjectId=9&LearningObjectInstanceId=8")
    }

    @Test func rebuildsTheLinkFromTheFilePageAddress() {
        let page = URL(string: "https://resource.itslearning.com/File/View.aspx?learningobjectid=11&LearningObjectInstanceId=12&x=y")!
        #expect(NativeFileLink.downloadLink(in: "<p>No link</p>", page: page)?.absoluteString
            == "https://resource.itslearning.com/Proxy/DownloadRedirect.ashx?LearningObjectId=11&LearningObjectInstanceId=12")
    }

    @Test func otherPagesGiveNoLink() {
        let page = URL(string: "https://resource.itslearning.com/ViewFile.aspx?LearningObjectId=11&LearningObjectInstanceId=12")!
        #expect(NativeFileLink.downloadLink(in: "", page: page) == nil)
        let missing = URL(string: "https://resource.itslearning.com/File/View.aspx?LearningObjectId=11")!
        #expect(NativeFileLink.downloadLink(in: "", page: missing) == nil)
    }
}
