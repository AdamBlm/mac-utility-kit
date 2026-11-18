import CoreGraphics
import Foundation
import UtilityCore

struct ScreenRecordingSettings: Equatable {
    enum Kind: String, CaseIterable, Identifiable {
        case display = "Display", window = "Window", region = "Region"
        var id: Self { self }
    }

    enum Source: Equatable {
        case display(UInt32)
        case window(UInt32)
        case region(UInt32, CGRect)
    }

    var kind = Kind.display
    var displayID: UInt32?
    var windowID: UInt32?
    var region: Source?
    var frameRate = 30
    var resolution = ScreenRecordingResolution.p1080
    var capturesSystemAudio = false
    var capturesMicrophone = false
    var microphoneID: String?
    var showsClicks = false
    var countdown = 3

    var source: Source? {
        switch kind {
        case .display: displayID.map(Source.display)
        case .window: windowID.map(Source.window)
        case .region: region
        }
    }
}
