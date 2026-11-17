import Foundation
import LaerCore

extension AppModel {
    /// Links inside a brief use this scheme. They never leave the app.
    static let noteLinkScheme = "laer-note"

    /// The brief Apple Intelligence made on this Mac for a lecture, when there is one (decision 0014).
    func lectureNote(for plan: PlanPreview, course: Course?) -> LectureNote? {
        briefs.generated[plan.planId]?.lectureNote
    }
}
