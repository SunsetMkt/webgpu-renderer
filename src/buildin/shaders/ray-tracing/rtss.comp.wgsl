let MAX_TRACE_COUNT: u32 = 1u;
let MAX_RAY_LENGTH: f32 = 9999.;
let BVH_DEPTH: i32 = ${BVH_DEPTH};
let BOX_HIT_TEST_MIN = -0.005;

struct VertexOutput {
  [[builtin(position)]] position: vec4<f32>;
  [[location(0)]] uv: vec2<f32>;
};

struct Ray {
  origin: vec3<f32>;
  dir: vec3<f32>;
  invDir: vec3<f32>;
};

struct HitPoint {
  position: vec3<f32>;
  metal: f32;
  diffuse: vec3<f32>;
  rough: f32;
  normal: vec3<f32>;
  meshIndex: u32;
  faceNormal: vec3<f32>;
  matIndex: u32;
  hit: bool;
};

struct Light {
  color: vec3<f32>;
  energy: f32;
  reflection: Ray;
  refraction: Ray;
};

struct BVHNode {
  isChild0Leaf: bool;
  isChild1Leaf: bool;
  child0Offset: i32;
  child1Offset: i32;
  max: vec3<f32>;
  min: vec3<f32>;
};

struct BVHLeaf {
  primitives: i32;
  indexes: vec3<i32>;
};

struct FragmentInfo {
  hit: bool;
  hitPoint: vec3<f32>;
  // areal coordinates
  weights: vec3<f32>;
  p0: vec3<f32>;
  p1: vec3<f32>;
  p2: vec3<f32>;
  uv0: vec2<f32>;
  uv1: vec2<f32>;
  uv2: vec2<f32>;
  n0: vec3<f32>;
  n1: vec3<f32>;
  n2: vec3<f32>;
  meshIndex: u32;
  matIndex: u32;
};

require('./common.chuck.wgsl');

fn genWorldRayByGBuffer(uv: vec2<f32>, gBInfo: HitPoint) -> Ray {
  let pixelSSPos: vec4<f32> = vec4<f32>(uv.x * 2. - 1., 1. - uv.y * 2., 0., 1.);
  var pixelWorldPos: vec4<f32> = global.u_viewInverse * global.u_projInverse * pixelSSPos;
  pixelWorldPos = pixelWorldPos / pixelWorldPos.w;

  var ray: Ray;

  ray.origin = pixelWorldPos.xyz / pixelWorldPos.w;
  ray.dir = normalize(gBInfo.position - ray.origin);
  ray.invDir = 1. / ray.dir;

  return ray;
};

fn getGBInfo(uv: vec2<f32>) -> HitPoint {
  var info: HitPoint;

  let wPMtl: vec4<f32> = textureSampleLevel(u_gbPositionMetal, u_samplerGB, uv, 0.);
  let dfRgh: vec4<f32> = textureSampleLevel(u_gbDiffuseRough, u_samplerGB, uv, 0.);
  let nomMesh: vec4<f32> = textureSampleLevel(u_gbNormalMeshIndex, u_samplerGB, uv, 0.);
  let fnomMat: vec4<f32> = textureSampleLevel(u_gbFaceNormalMatIndex, u_samplerGB, uv, 0.);

  info.hit = u32(nomMesh.w) != 1u;
  info.position = wPMtl.xyz;
  info.metal = wPMtl.w;
  info.diffuse = dfRgh.xyz;
  info.rough = dfRgh.w;
  info.normal = nomMesh.xyz;
  info.meshIndex = u32(nomMesh.w) - 2u;
  info.faceNormal = fnomMat.xyz;
  info.matIndex = u32(fnomMat.w);

  return info;
};

fn getBVHNodeInfo(offset: i32) -> BVHNode {
  var node: BVHNode;
  let data0: vec4<f32> = u_bvh.value[offset];
  let data1: vec4<f32> = u_bvh.value[offset + 1];
  let child0: u32 = bitcast<u32>(data0[0]);
  let child1: u32 = bitcast<u32>(data1[0]);
  node.isChild0Leaf = (child0 >> 31u) != 0u;
  node.child0Offset = i32((child0 << 1u) >> 1u);
  node.isChild1Leaf = (child1 >> 31u) != 0u;
  node.child1Offset = i32((child1 << 1u) >> 1u);
  node.min = data0.yzw;
  node.max = data1.yzw;

  return node;
}

fn getBVHLeafInfo(offset: i32) -> BVHLeaf {
  var leaf: BVHLeaf;
  let data1: vec4<f32> = u_bvh.value[offset];
  leaf.primitives = bitcast<i32>(data1.x);
  leaf.indexes = bitcast<vec3<i32>>(data1.yzw);

  return leaf;
}

// https://tavianator.com/2011/ray_box.html
fn boxHitTest(ray: Ray, max: vec3<f32>, min: vec3<f32>) -> f32 {
  let t1: vec3<f32> = (min - ray.origin) * ray.invDir;
  let t2: vec3<f32> = (max - ray.origin) * ray.invDir;
  let tvmin: vec3<f32> = min(t1, t2);
  let tvmax: vec3<f32> = max(t1, t2);
  let tmin: f32 = max(tvmin.x, max(tvmin.y, tvmin.z));
  let tmax: f32 = min(tvmax.x, min(tvmax.y, tvmax.z));

  if (tmin > tmax || tmin > MAX_RAY_LENGTH) {
    return -1.;
  }
  
  if (tmin > 0.) {
    return tmin;
  }

  return tmax;
}

fn getFaceNormal(frag: FragmentInfo) -> vec3<f32> {
  return normalize(cross(frag.p1 - frag.p0, frag.p2 - frag.p0));
}

fn getNormal(
  frag: FragmentInfo, faceNormal: vec3<f32>, uv: vec2<f32>,
  textureId: i32, normalScale: f32
) -> vec3<f32> {
  var normal: vec3<f32> = normalize(
    frag.n0 * frag.weights[0] + frag.n0 * frag.weights[1] + frag.n0 * frag.weights[2]
  );
  normal = normal * sign(dot(normal, faceNormal));

  if (textureId == -1) {
    return normal;
  }

  // // http://www.thetenthplanet.de/archives/1180
  let dp1: vec3<f32> = frag.p1 - frag.p0;
  let dp2: vec3<f32> = frag.p2 - frag.p0;
  let duv1: vec2<f32> = frag.uv2 - frag.uv0;
  let duv2: vec2<f32> = frag.uv1 - frag.uv0;
  let dp2perp: vec3<f32> = cross(dp2, normal);
  let dp1perp: vec3<f32> = cross(normal, dp1);
  var dpdu: vec3<f32> = dp2perp * duv1.x + dp1perp * duv2.x;
  var dpdv: vec3<f32> = dp2perp * duv1.y + dp1perp * duv2.y;
  let invmax: f32 = inverseSqrt(max(dot(dpdu, dpdu), dot(dpdv, dpdv)));
  dpdu = dpdu * invmax;
  dpdv = dpdv * invmax;
  let tbn: mat3x3<f32> = mat3x3<f32>(dpdu, dpdv, normal);
  var tNormal: vec3<f32> = 2. * textureSampleLevel(u_normalTextures, u_sampler, uv, textureId, 0.).xyz - 1.;
  tNormal = tNormal * vec3<f32>(normalScale, normalScale, 1.);

  return normalize(tbn * tNormal);
}


fn triangleHitTest(ray: Ray, leaf: BVHLeaf) -> FragmentInfo {
  var info: FragmentInfo;
  let indexes: vec3<i32> = leaf.indexes;
  info.p0 = u_positions.value[indexes[0]];
  info.p1 = u_positions.value[indexes[1]];
  info.p2 = u_positions.value[indexes[2]];

  let e0: vec3<f32> = info.p1 - info.p0;
  let e1: vec3<f32> = info.p2 - info.p0;
  let p: vec3<f32> = cross(ray.dir, e1);
  var det: f32 = dot(e0, p);
  var t: vec3<f32> = ray.origin - info.p0;

  if (det < 0.) {
    t = -t;
    det = -det;
  }

  if (det < 0.0001) {
    return info;
  }

  let u: f32 = dot(t, p);

  if (u < 0. || u > det) {
    return info;
  }

  let q: vec3<f32> = cross(t, e0);
  let v: f32 = dot(ray.dir, q);

  if (v < 0. || v + u > det) {
    return info;
  }

  let lt: f32 = dot(e1, q);
  let invDet: f32 = 1. / det;

  info.hit = true;
  info.hitPoint = ray.origin + ray.dir * lt * invDet;
  info.weights = vec3<f32>(0., u, v) * invDet;
  info.weights.x = 1. - info.weights.y - info.weights.z;
  info.uv0 = u_uvs.value[indexes.x];
  info.uv1 = u_uvs.value[indexes.y];
  info.uv2 = u_uvs.value[indexes.z];
  info.n0 = u_normals.value[indexes.x];
  info.n1 = u_normals.value[indexes.y];
  info.n2 = u_normals.value[indexes.z];
  info.meshIndex = u_meshMatIndexes.value[indexes.x].x;
  info.matIndex = u_meshMatIndexes.value[indexes.x].y;

  return info;
}

fn fillHitPoint(frag: FragmentInfo) -> HitPoint {
  var info: HitPoint;

  info.hit = true;
  info.meshIndex = frag.meshIndex;
  info.matIndex = frag.matIndex;
  info.position = frag.p0 * frag.weights[0] + frag.p1 * frag.weights[1] + frag.p2 * frag.weights[2];
  info.faceNormal = getFaceNormal(frag);
  let uv: vec2<f32> = frag.uv0 * frag.weights[0] + frag.uv1 * frag.weights[1] + frag.uv2 * frag.weights[2];
  let metallicRoughnessFactorNormalScale: vec3<f32> = material.u_metallicRoughnessFactorNormalScales[frag.matIndex];
  let textureIds: vec4<i32> = material.u_matId2TexturesId[frag.matIndex];  
  info.normal = getNormal(frag, info.faceNormal, uv, textureIds[1], metallicRoughnessFactorNormalScale[2]);
  info.metal = getMetallic(metallicRoughnessFactorNormalScale[0], textureIds[2], uv);
  info.diffuse = getBaseColor(material.u_baseColorFactors[frag.matIndex], textureIds[0], uv).rgb;
  info.rough = getRoughness(metallicRoughnessFactorNormalScale[1], textureIds[0], uv);

  return info;
}

fn leafHitTest(ray: Ray, offset: i32) -> HitPoint {
  var hit: HitPoint;
  var info: FragmentInfo;
  var leaf: BVHLeaf = getBVHLeafInfo(offset);
  let primitives: i32 = leaf.primitives;
  
  for (var i: i32 = 0; i < primitives; i = i + 1) {
    info = triangleHitTest(ray, leaf);

    if (info.hit) {
      break;
    }

    leaf = getBVHLeafInfo(offset + i);
  }

  if (info.hit) {
    hit = fillHitPoint(info);
  }

  return hit;
}

fn hitTest(ray: Ray) -> HitPoint {
  var hit: HitPoint;
  var node: BVHNode = getBVHNodeInfo(0);
  var hited: f32 = boxHitTest(ray, node.max, node.min);

  if (hited <= 0.) {
    hit.rough = hited;
    return hit;
  }

  for (var i: i32 = 0; i < BVH_DEPTH; i = i + 1) {
    if (node.isChild0Leaf) {
      hit = leafHitTest(ray, node.child0Offset);
      break;
    }

    if (node.isChild1Leaf) {
      hit = leafHitTest(ray, node.child1Offset);
      break;
    }

    let child0Offset: i32 = node.child0Offset;
    let child1Offset: i32 = node.child1Offset;

    node = getBVHNodeInfo(child0Offset);
    hited = boxHitTest(ray, node.max, node.min);

    if (hited > BOX_HIT_TEST_MIN) {
      continue;
    }

    node = getBVHNodeInfo(child1Offset);
    hited = boxHitTest(ray, node.max, node.min);

    if (hited <= BOX_HIT_TEST_MIN) {
      hit.rough = hited;
      break;
    }
  }

  return hit;
}

fn calcLight(ray: Ray, hit: HitPoint, isLastOut: bool) -> Light {
  var light: Light;

  if (isLastOut) {
    light.color = textureSampleLevel(u_envTexture, u_sampler, ray.dir, 0.).rgb;
    light.energy = 1.;
    return light;
  }

  light.color = hit.diffuse;
  light.energy = .8;

  light.reflection.origin = hit.position;
  light.reflection.dir = reflect(ray.dir, hit.normal);
  light.reflection.invDir = 1. / light.reflection.dir;

  return light;
}

fn traceLight(startRay: Ray, gBInfo: HitPoint, debugIndex: i32) -> vec3<f32> {
  var light: Light = calcLight(startRay, gBInfo, false);
  var energy: f32 = light.energy;
  var lightColor: vec3<f32> = light.color * energy;
  var hit: HitPoint;
  var ray: Ray = light.reflection;

  hit = hitTest(ray);
  if (hit.hit) {
    lightColor = hit.diffuse;
  }
  // lightColor = hit.diffuse;
  // lightColor = abs(light.reflection.origin);
  // lightColor = abs(light.reflection.dir);

  u_debugInfo.rays[debugIndex].origin = vec4<f32>(ray.origin, hit.rough);
  u_debugInfo.rays[debugIndex].dir = vec4<f32>(ray.dir, 0.);
  u_debugInfo.rays[debugIndex].normal = vec4<f32>(gBInfo.normal, 0.);
  u_debugInfo.rays[debugIndex].preOrigin = vec4<f32>(startRay.origin, 0.);
  u_debugInfo.rays[debugIndex].preDir = vec4<f32>(startRay.dir, 0.);

  // lightColor.z = -light.reflection.dir.z;

  // for (var i: u32 = 0u; i < MAX_TRACE_COUNT; i = i + 1u) {
  //   hit = hitTest(ray);
  //   let isLastOut: bool = !hit.hit;

  //   light = calcLight(ray, hit, isLastOut);
  //   energy = energy * light.energy;
  //   lightColor = lightColor + light.color * energy;
  //   ray = light.reflection;

  //   if (energy < 0.01 || isLastOut) {
  //     break;
  //   }
  // }

  return lightColor;
}

fn traceShadow(ray: Ray) -> f32 {
  return 1.;
}

[[stage(compute), workgroup_size(16, 16, 1)]]
fn main(
  [[builtin(workgroup_id)]] workGroupID : vec3<u32>,
  [[builtin(local_invocation_id)]] localInvocationID : vec3<u32>
) {
  let screenSize: vec2<i32> = textureDimensions(u_gbPositionMetal, 0);
  let groupOffset: vec2<i32> = vec2<i32>(workGroupID.xy) * 16;
  let baseIndex: vec2<i32> = groupOffset + vec2<i32>(localInvocationID.xy);
  let baseUV: vec2<f32> = vec2<f32>(baseIndex) / vec2<f32>(screenSize);
  let gBInfo: HitPoint = getGBInfo(baseUV);

  if (!gBInfo.hit) {
    let t: vec4<f32> = global.u_skyVP * vec4<f32>(baseUV.x * 2. - 1., 1. - baseUV.y * 2., 1., 1.);
    let cubeUV: vec3<f32> = normalize(t.xyz / t.w);
    let bgColor: vec4<f32> = textureSampleLevel(u_envTexture, u_sampler, cubeUV, 0.);
    textureStore(u_output, baseIndex, vec4<f32>(bgColor.rgb * global.u_envColor.rgb, bgColor.a));
    return;
  }

  let worldRay: Ray = genWorldRayByGBuffer(baseUV, gBInfo);
  let light: vec3<f32> = traceLight(worldRay, gBInfo, baseIndex.x + baseIndex.y * screenSize.x);
  let shadow: f32 = traceShadow(worldRay);

  textureStore(u_output, baseIndex, vec4<f32>(light * shadow, 1.));
}
