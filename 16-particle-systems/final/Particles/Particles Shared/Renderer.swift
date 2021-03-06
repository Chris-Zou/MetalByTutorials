/**
 * Copyright (c) 2018 Razeware LLC
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * Notwithstanding the foregoing, you may not use, copy, modify, merge, publish,
 * distribute, sublicense, create a derivative work, and/or sell copies of the
 * Software in any work that is designed, intended, or marketed for pedagogical or
 * instructional purposes related to programming, coding, application development,
 * or information technology.  Permission for such use, copying, modification,
 * merger, publication, distribution, sublicensing, creation of derivative works,
 * or sale is expressly withheld.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 */

import MetalKit

class Renderer: NSObject, MTKViewDelegate {
    
  static var device: MTLDevice!
  let commandQueue: MTLCommandQueue
  var particlesPipelineState: MTLComputePipelineState!
  var renderPipelineState: MTLRenderPipelineState!
  
  var emitters: [Emitter] = []
  
  init?(metalView: MTKView) {
    guard let device = MTLCreateSystemDefaultDevice(),
      let commandQueue = device.makeCommandQueue() else { return nil }
    Renderer.device = device
    self.commandQueue = commandQueue
    super.init()
    metalView.delegate = self
    metalView.framebufferOnly = false
    metalView.clearColor = MTLClearColor(red: 0.2, green: 0.2,
                                         blue: 0.2, alpha: 1)
    buildPipelineStates()

    let snowEmitter = snow(size: metalView.drawableSize)
    snowEmitter.position = [0, Float(metalView.drawableSize.height)]
    emitters.append(snowEmitter)

    let fireEmitter = fire(size: metalView.drawableSize)
    fireEmitter.position = [0, -10]
    emitters.append(fireEmitter)
  }
  
  private func buildPipelineStates() {
    do {
      guard let library = Renderer.device.makeDefaultLibrary(),
        let function = library.makeFunction(name: "compute") else { return }
      
      // particle update pipeline state
      particlesPipelineState = try Renderer.device.makeComputePipelineState(function: function)
      
      // render pipeline state
      let vertexFunction = library.makeFunction(name: "vertex_particle")
      let fragmentFunction = library.makeFunction(name: "fragment_particle")
      let descriptor = MTLRenderPipelineDescriptor()
      descriptor.vertexFunction = vertexFunction
      descriptor.fragmentFunction = fragmentFunction
      descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
      
      descriptor.colorAttachments[0].isBlendingEnabled = true
      descriptor.colorAttachments[0].rgbBlendOperation = .add
      descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
      descriptor.colorAttachments[0].destinationRGBBlendFactor = .one
      
      renderPipelineState = try
        Renderer.device.makeRenderPipelineState(descriptor: descriptor)
      renderPipelineState = try Renderer.device.makeRenderPipelineState(descriptor: descriptor)
    } catch let error {
      print(error.localizedDescription)
    }
  }
  
  public func draw(in view: MTKView) {
    for emitter in emitters {
      emitter.emit()
    }
    guard let commandBuffer = commandQueue.makeCommandBuffer(),
          let descriptor = view.currentRenderPassDescriptor,
          let drawable = view.currentDrawable else { return }
    
    // first command encoder
    // update the particle emitters
    guard let computeEncoder = commandBuffer.makeComputeCommandEncoder()
      else { return }
    computeEncoder.setComputePipelineState(particlesPipelineState)
    let width = particlesPipelineState.threadExecutionWidth
    let threadsPerGroup = MTLSizeMake(width, 1, 1)
 
    func dispatchThreads(particleCount: Int) {
    let threadsPerGrid = MTLSizeMake(particleCount, 1, 1)
    computeEncoder.dispatchThreads(threadsPerGrid,
                                   threadsPerThreadgroup: threadsPerGroup)
    }
    
    for emitter in emitters {
      computeEncoder.setBuffer(emitter.particleBuffer, offset: 0, index: 0)
      computeEncoder.setBytes(&emitter.particleCount,
                              length: MemoryLayout<uint>.stride, index: 1)
      #if os(iOS)
      if Renderer.device.supportsFeatureSet(.iOS_GPUFamily4_v1) {
        dispatchThreads(particleCount: emitter.particleCount)
      } else {
        let threads = min(particlesPipelineState.threadExecutionWidth,
                          emitter.currentParticles)
        let threadsPerThreadgroup = MTLSize(width: threads,
                                            height: 1,
                                            depth: 1)
        let groups = emitter.currentParticles / threads + 1
        let groupsPerGrid = MTLSize(width: groups,
                                    height: 1,
                                    depth: 1)
        computeEncoder.dispatchThreadgroups(groupsPerGrid,
                                            threadsPerThreadgroup: threadsPerThreadgroup)
      }
      #elseif os(macOS)
      dispatchThreads(particleCount: emitter.particleCount)
      #endif
    }
    computeEncoder.endEncoding()

    
    // second command encoder
    // render the particle emitters
    
    let renderEncoder =
      commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)!
    renderEncoder.setRenderPipelineState(renderPipelineState)
    var size = float2(Float(view.drawableSize.width),
                      Float(view.drawableSize.height))
    renderEncoder.setVertexBytes(&size,
                                 length: MemoryLayout<float2>.stride,
                                 index: 0)
    for emitter in emitters {
      renderEncoder.setVertexBuffer(emitter.particleBuffer,
                                    offset: 0, index: 1)
      renderEncoder.setVertexBytes(&emitter.position,
                                   length: MemoryLayout<float2>.stride,
                                   index: 2)
      renderEncoder.setFragmentTexture(emitter.particleTexture, index: 0)
      renderEncoder.drawPrimitives(type: .point, vertexStart: 0,
                                   vertexCount: 1,
                                   instanceCount: emitter.currentParticles)
    }
    renderEncoder.endEncoding()
    commandBuffer.present(drawable)
    commandBuffer.commit()
  }
  
  public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
    emitters.removeAll()
    let snowEmitter = snow(size: size)
    snowEmitter.position = [0, Float(size.height)]
    emitters.append(snowEmitter)
    let fireEmitter = fire(size: size)
    fireEmitter.position = [0, -10]
    emitters.append(fireEmitter)
  }
}
