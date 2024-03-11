//
//  ImmersiveView.swift
//  MetalSplatter SampleApp
//
//  Created by minjune Song on 3/9/24.
//

import Foundation
import SwiftUI
import RealityKit

struct ImmersiveView: View {
    var body: some View {
        RealityView { content in
            
            // A 20m box that receives hits.
            let collisionBox = makeCollisionBox(size: 20)
            
            content.add(collisionBox)
            
        }.gesture(tapGesture)
    }
    
    private var tapGesture: some Gesture {
        TapGesture()
            .targetedToAnyEntity()
            .onEnded { value in
                print(value.entity.name)
            }
    }
}

func makeCollisionBox(size: Float) -> Entity {
    
    let smallDimension: Float = 0.001
    let offset = size / 2
    
    // right face
    let right = Entity()
    right.name = "right"
    right.components.set(CollisionComponent(shapes: [.generateBox(width: smallDimension, height: size, depth: size)]))
    right.position.x = offset
    
    // left face
    let left = Entity()
    left.name = "left"
    left.components.set(CollisionComponent(shapes: [.generateBox(width: smallDimension, height: size, depth: size)]))
    left.position.x = -offset
    
    // top face
    let top = Entity()
    top.name = "top"
    top.components.set(CollisionComponent(shapes: [.generateBox(width: size, height: smallDimension, depth: size)]))
    top.position.y = offset
    
    // bottom face
    let bottom = Entity()
    bottom.name = "bottom"
    bottom.components.set(CollisionComponent(shapes: [.generateBox(width: size, height: smallDimension, depth: size)]))
    bottom.position.y = -offset
    
    // front face
    let front = Entity()
    front.name = "front"
    front.components.set(CollisionComponent(shapes: [.generateBox(width: size, height: size, depth: smallDimension)]))
    front.position.z = offset
    
    // back face
    let back = Entity()
    back.name = "back"
    back.components.set(CollisionComponent(shapes: [.generateBox(width: size, height: size, depth: smallDimension)]))
    back.position.z = -offset
    
    // All faces.
    let faces = [right, left, top, bottom, front, back]
    
    for face in faces {
        face.components.set(InputTargetComponent())
    }
    
    // parent to hold all of the entities.
    let entity = Entity()
    entity.children.append(contentsOf: faces)
        
    return entity
}
