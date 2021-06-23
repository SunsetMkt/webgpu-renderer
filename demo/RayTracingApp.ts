/**
 * RayTracingApp.ts
 * 
 * @Author  : hikaridai(hikaridai@tencent.com)
 * @Date    : 6/11/2021, 5:56:30 PM
*/
import * as H from '../src/index';

const MODEL_SRC = '/assets/models/simple/scene.gltf';

export default class RayTracingApp {
  private _scene: H.Scene;
  private _camControl: H.NodeControl;
  private _model: H.IGlTFResource;
  private _lights: H.Light[];
  private _camera: H.Camera;
  private _gBufferRT: H.RenderTexture;
  private _gBufferDebugMesh: H.ImageMesh;
  protected _rtManager: H.RayTracingManager;
  protected _rtOutput: H.RenderTexture;
  protected _rtBlit: H.ImageMesh;

  public async init() {
    const {renderEnv} = H;

    const _scene = this._scene = new H.Scene();
    const rootNode = this._scene.rootNode = new H.Node();
    this._camControl = new H.NodeControl('arc');

    rootNode.addChild(this._camera = new H.Camera(
      {clearColor: [0, 1, 0, 1]},
      {near: 0.01, far: 100, fov: Math.PI / 3}
    ));
    this._camera.pos.set([0, 0, 6]);

    this._gBufferRT = new H.RenderTexture({
      width: renderEnv.width,
      height: renderEnv.height,
      colors: [
        {name: 'positionMetal', format: 'rgba16float'},
        {name: 'diffuseRough', format: 'rgba16float'},
        {name: 'normalMeshIndex', format: 'rgba16float'},
        {name: 'faceNormalMatIndex', format: 'rgba16float'}
      ],
      depthStencil: {needStencil: false}
    });

    this._gBufferDebugMesh = new H.ImageMesh(new H.Material(H.buildinEffects.iRTGShow));
    this._connectGBufferRenderTexture(this._gBufferDebugMesh.material);

    this._rtOutput = new H.RenderTexture({
      width: renderEnv.width,
      height: renderEnv.height,
      forCompute: true,
      colors: [{name: 'color', format: 'rgba8unorm'}]
    });
    this._rtBlit = new H.ImageMesh(new H.Material(H.buildinEffects.iBlit, {u_texture: this._rtOutput}));
    
    const model = this._model = await H.resource.load({type: 'gltf', name: 'scene.gltf', src: MODEL_SRC});
    if (model.cameras.length) {
      this._camera = model.cameras[0];
    }
    this._lights = model.lights;
    _scene.rootNode.addChild(model.rootNode);
    
    this._camControl.control(this._camera, new H.Node());

    this._frame();
  }

  public update(dt: number) {
    this._frame();
  }

  private _frame() {
    const {_scene} = this;

    _scene.startFrame();
    
    if (!this._rtManager) {
      this._rtManager = new H.RayTracingManager();
      this._rtManager.process(this._scene.cullCamera(this._camera), this._rtOutput);
      this._connectGBufferRenderTexture(this._rtManager.rtUnit);
    }
    
    this._rtManager.rtUnit.setUniform('u_randomSeed', new Float32Array([Math.random(), Math.random(), Math.random(), Math.random()]));
    // this._showBVH();
    this._renderGBuffer();
    // this._showGBufferResult();
    this._computeRTSS();
    _scene.endFrame();
  }

  private _renderGBuffer() {
    this._scene.setRenderTarget(this._gBufferRT);
    this._scene.renderCamera(this._camera, [this._rtManager.gBufferMesh]);
  }

  protected _computeRTSS() {
    this._scene.setRenderTarget(null);
    this._scene.computeUnits([this._rtManager.rtUnit], this._camera, this._lights);
    this._scene.renderImages([this._rtBlit]);
  }

  private _showGBufferResult() {
    this._scene.setRenderTarget(null);
    this._scene.renderImages([this._gBufferDebugMesh], this._camera);
  }

  private _showBVH() {
    this._scene.setRenderTarget(null);
    this._scene.renderCamera(this._camera, [
      ...this._scene.cullCamera(this._camera),
      this._rtManager.bvhDebugMesh
    ]);
  }

  private _connectGBufferRenderTexture(material: H.Material | H.ComputeUnit) {
    material.setUniform('u_gbPositionMetal', this._gBufferRT, 'positionMetal');
    material.setUniform('u_gbDiffuseRough', this._gBufferRT, 'diffuseRough');
    material.setUniform('u_gbNormalMeshIndex', this._gBufferRT, 'normalMeshIndex');
    material.setUniform('u_gbFaceNormalMatIndex', this._gBufferRT, 'faceNormalMatIndex');
  }
}
