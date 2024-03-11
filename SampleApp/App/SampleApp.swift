#if os(visionOS)
import CompositorServices
#endif
import SwiftUI
import ARKit

@main
struct SampleApp: App {
    @State var session = ARKitSession()
    @StateObject var model:  🥽AppModel = .init()
    
    var body: some Scene {
        WindowGroup("MetalSplatter Sample App", id: "main") {
            ContentView()
        }
        
#if os(macOS)
        WindowGroup(for: ModelIdentifier.self) { modelIdentifier in
            MetalKitSceneView(modelIdentifier: modelIdentifier.wrappedValue)
                .navigationTitle(modelIdentifier.wrappedValue?.description ?? "No Model")
        }
#endif // os(macOS)
        
        // add collision window like 1 m in front of person
        // if they pinch, move the model in the - direction of pinch
        // if they swipe gesture, rotate the model accordingly
        ImmersiveSpace(for: ModelIdentifier.self) { modelIdentifier in
            CompositorLayer(configuration: ContentStageConfiguration()) { layerRenderer in
                Task {
                    do {
                        model.observeAuthorizationStatus()
                        model.run()
                    } catch {
                        print("cannot request auth")
                    }
                }
                
                let renderer = VisionSceneRenderer(layerRenderer, model)
                do {
                    try renderer.load(modelIdentifier.wrappedValue)
                } catch {
                    print("Error loading model: \(error.localizedDescription)")
                }
                renderer.startRenderLoop()
                
                // TODO
                // handle translation
                /*
                layerRenderer.onSpatialEvent = { eventCollection in
                    var events = eventCollection.map { mySpatialEvent($0) }
                    myEnginePushSpatialEvents(engine, &events, events.count)
                }
                 */
                // so model is gonna get updated every time it sees hand
                // we just have to draw the genericBalls in renderer then
            }
        }
        .immersionStyle(selection: .constant(.mixed), in: .full)
        
    }
}

