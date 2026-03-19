import WidgetKit
import SwiftUI

@main
struct YourPodsWidgetBundle: WidgetBundle {
    var body: some Widget {
        YourPodsNowPlayingWidget()
        YourPodsComplicationWidget()
    }
}
