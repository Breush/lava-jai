/*
    An eye is a point of view within a scene.
    Renderers define how many eyes they need (for instance, a VrRenderer needs two eyes).

    An eye is defined with two matrices:
        - The view matrix, which own inverse is the position/orientation of the camera
          in world-space. You usually want to make a look_at matrix for this one.
        - The projection matrix, which is usually a perspective matrix transforming
          local Z-oriented coordinates into Normalized Device Coordinates.

    Editing eyes directly can be a bit hard, you might want to make a camera to control it.
    ```
    orbitCamera := renderer_make_orbit_camera(renderer, eyeIndex); // eyeIndex defaults to 0 if not provided
    ```
*/
Eye :: struct {
    extent : Chamber.uvec2;
    viewMatrix : Chamber.mat4;
    projectionMatrix : Chamber.mat4;

    shaderObject : EyeShaderObject;

    frustum : struct {
        // :NearFarEyeFrustumCulling
        forward : Chamber.vec3;
        leftNormal : Chamber.vec3;
        rightNormal : Chamber.vec3;
        bottomNormal : Chamber.vec3;
        topNormal : Chamber.vec3;
        leftDistance : float;
        rightDistance : float;
        bottomDistance : float;
        topDistance : float;
    };
}

EyeShaderObject :: struct {                  // 72 bytes
    viewMatrixRow0 : Chamber.vec4;           // 16 viewMatrixRow[0]
    viewMatrixRow1 : Chamber.vec4;           // 16 viewMatrixRow[1]
    viewMatrixRow2 : Chamber.vec4;           // 16 viewMatrixRow[2]
    projectionMatrixFactors1 : Chamber.vec4; // 16 [0][0] [1][1] [2][2] [2][3]
    projectionMatrixFactors2 : Chamber.vec2; // 8 [0][2] [1][2]
    lastChangeFrame : u32;                   // @todo Temporary, waiting for motion buffer.
}

eye_init :: (eye : *Eye, extent : Chamber.uvec2) {
    eye.extent = extent;
    eye.viewMatrix = Chamber.look_at_matrix(.{0, 0, 0}, .{1, 0, 0});
    Chamber.infinite_perspective_projection(*eye.projectionMatrix, #run Chamber.to_radians(100.),
                                            cast(float32) extent.width / cast(float32) extent.height, 0.01);
    eye_commit(eye);
}

eye_commit :: (eye : *Eye) {
    eye.shaderObject.viewMatrixRow0.std = eye.viewMatrix.v[0];
    eye.shaderObject.viewMatrixRow1.std = eye.viewMatrix.v[1];
    eye.shaderObject.viewMatrixRow2.std = eye.viewMatrix.v[2];

    // For symmetric projections
    eye.shaderObject.projectionMatrixFactors1.x = eye.projectionMatrix.coef[0][0];
    eye.shaderObject.projectionMatrixFactors1.y = eye.projectionMatrix.coef[1][1];
    eye.shaderObject.projectionMatrixFactors1.z = eye.projectionMatrix.coef[2][2];
    eye.shaderObject.projectionMatrixFactors1.w = eye.projectionMatrix.coef[2][3];

    // Extended for non-symmetric projections
    eye.shaderObject.projectionMatrixFactors2.x = eye.projectionMatrix.coef[0][2];
    eye.shaderObject.projectionMatrixFactors2.y = eye.projectionMatrix.coef[1][2];

    // @note Can't know the frame index here, the renderer will insert it.
    eye.shaderObject.lastChangeFrame = 0xFFFF_FFFF;

    // Updating the frustum
    projectionMatrixInverse := inverse(eye.projectionMatrix);
    viewMatrixInverse := inverse(eye.viewMatrix);

    // @note Far is at 0, by our conventions (see linear-algebra in Chamber module).
    topLeftNearLocal := projectionMatrixInverse * Chamber.vec4.{-1, -1, 1, 1}; // NDC to local
    topRightNearLocal := projectionMatrixInverse * Chamber.vec4.{1, -1, 1, 1};
    bottomLeftNearLocal := projectionMatrixInverse * Chamber.vec4.{-1, 1, 1, 1};
    bottomRightNearLocal := projectionMatrixInverse * Chamber.vec4.{1, 1, 1, 1};

    topLeftFarLocal := projectionMatrixInverse * Chamber.vec4.{-1, -1, 0, 1};
    topRightFarLocal := projectionMatrixInverse * Chamber.vec4.{1, -1, 0, 1};
    bottomLeftFarLocal := projectionMatrixInverse * Chamber.vec4.{-1, 1, 0, 1};
    bottomRightFarLocal := projectionMatrixInverse * Chamber.vec4.{1, 1, 0, 1};

    // W component can be zeroed with orthographic projections.
    if topLeftNearLocal.w != 0 then topLeftNearLocal /= topLeftNearLocal.w;
    if topRightNearLocal.w != 0 then topRightNearLocal /= topRightNearLocal.w;
    if bottomLeftNearLocal.w != 0 then bottomLeftNearLocal /= bottomLeftNearLocal.w;
    if bottomRightNearLocal.w != 0 then bottomRightNearLocal /= bottomRightNearLocal.w;
    if topLeftFarLocal.w != 0 then topLeftFarLocal /= topLeftFarLocal.w;
    if topRightFarLocal.w != 0 then topRightFarLocal /= topRightFarLocal.w;
    if bottomLeftFarLocal.w != 0 then bottomLeftFarLocal /= bottomLeftFarLocal.w;
    if bottomRightFarLocal.w != 0 then bottomRightFarLocal /= bottomRightFarLocal.w;

    topLeftNear := (viewMatrixInverse * topLeftNearLocal).xyz;
    topRightNear := (viewMatrixInverse * topRightNearLocal).xyz;
    bottomLeftNear := (viewMatrixInverse * bottomLeftNearLocal).xyz;
    bottomRightNear := (viewMatrixInverse * bottomRightNearLocal).xyz;

    topLeftFar := (viewMatrixInverse * topLeftFarLocal).xyz;
    topRightFar := (viewMatrixInverse * topRightFarLocal).xyz;
    bottomLeftFar := (viewMatrixInverse * bottomLeftFarLocal).xyz;
    bottomRightFar := (viewMatrixInverse * bottomRightFarLocal).xyz;

    origin := viewMatrixInverse.v[3].xyz;

    eye.frustum.forward.std = normalize(cross(topLeftNear - bottomLeftNear, bottomRightNear - bottomLeftNear));
    eye.frustum.leftNormal.std = normalize(cross(topLeftFar - topLeftNear, bottomLeftNear - topLeftNear));
    eye.frustum.rightNormal.std = normalize(cross(bottomRightFar - bottomRightNear, topRightNear - bottomRightNear));
    eye.frustum.bottomNormal.std = normalize(cross(bottomLeftFar - bottomLeftNear, bottomRightFar - bottomLeftNear));
    eye.frustum.topNormal.std = normalize(cross(topRightFar - topRightNear, topLeftFar - topRightNear));

    eye.frustum.leftDistance = dot(topLeftNear, eye.frustum.leftNormal);
    eye.frustum.rightDistance = dot(bottomRightNear, eye.frustum.rightNormal);
    eye.frustum.bottomDistance = dot(bottomLeftNear, eye.frustum.bottomNormal);
    eye.frustum.topDistance = dot(topRightNear, eye.frustum.topNormal);
}

eye_is_seeing :: (eye : *Eye, sphere : Chamber.Sphere) -> bool {
    // @todo :NearFarEyeFrustumCulling Missing near/far checks...
    if dot(sphere.center, eye.frustum.leftNormal) - sphere.radius > eye.frustum.leftDistance then return false;
    if dot(sphere.center, eye.frustum.rightNormal) - sphere.radius > eye.frustum.rightDistance then return false;
    if dot(sphere.center, eye.frustum.topNormal) - sphere.radius > eye.frustum.topDistance then return false;
    if dot(sphere.center, eye.frustum.bottomNormal) - sphere.radius > eye.frustum.bottomDistance then return false;
    return true;
}

/*
    Cameras are a way to control an eye as provided by renderers.

    Cameras are not provided to be "created" as they are just controllers.
    You have to manage their liveness then.
*/
OrbitCamera :: struct {
    eye : *Eye;

    origin : Chamber.vec3;
    target : Chamber.vec3;

    fovX : float32;
    nearClip : float32;
}

orbit_camera_init :: (orbitCamera : *OrbitCamera, eye : *Eye) {
    orbitCamera.eye = eye;
    orbit_camera_infinite_perspective_projection(orbitCamera, #run Chamber.to_radians(100), 0.01, false);
    orbit_camera_origin_target(orbitCamera, .{0, 0, 0}, .{1, 0, 0}, false);
    eye_commit(eye);
}

orbit_camera_infinite_perspective_projection :: (orbitCamera : *OrbitCamera, fovX : float32, nearClip : float32, $commit := true) {
    orbitCamera.fovX = fovX;
    orbitCamera.nearClip = nearClip;
    aspectRatio := cast(float32) orbitCamera.eye.extent.width / cast(float32) orbitCamera.eye.extent.height;
    Chamber.infinite_perspective_projection(*orbitCamera.eye.projectionMatrix, fovX, aspectRatio, nearClip);

    #if commit {
        eye_commit(orbitCamera.eye);
    }
}

orbit_camera_origin_target :: (orbitCamera : *OrbitCamera, origin : Chamber.vec3, target : Chamber.vec3, $commit := true) {
    orbitCamera.origin = origin;
    orbitCamera.target = target;
    orbitCamera.eye.viewMatrix = Chamber.look_at_matrix(origin, target);

    #if commit {
        eye_commit(orbitCamera.eye);
    }
}

orbit_camera_radius :: (using orbitCamera : *OrbitCamera) -> float32 #must {
    return length(target - origin);
}

orbit_camera_add_to_radius :: (using orbitCamera : *OrbitCamera, delta : float32, $commit := true) {
    radius := length(target - origin) + delta;
    direction := normalize(target - origin);
    origin.std = target - radius * direction;

    orbitCamera.eye.viewMatrix = Chamber.look_at_matrix(orbitCamera.origin, orbitCamera.target);

    #if commit {
        eye_commit(orbitCamera.eye);
    }
}

orbit_camera_rotate_around_target :: (orbitCamera : *OrbitCamera, longitudeAngle : float32, latitudeAngle : float32, $commit := true) {
    orbitCamera.origin.std += Chamber.rotate_around_target(orbitCamera.origin, orbitCamera.target, latitudeAngle, longitudeAngle);
    orbitCamera.eye.viewMatrix = Chamber.look_at_matrix(orbitCamera.origin, orbitCamera.target);

    #if commit {
        eye_commit(orbitCamera.eye);
    }
}
