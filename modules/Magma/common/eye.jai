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
}

EyeShaderObject :: struct {                  // 72 bytes
    viewMatrixRow0 : Chamber.vec4;           // 16 viewMatrixRow[0]
    viewMatrixRow1 : Chamber.vec4;           // 16 viewMatrixRow[1]
    viewMatrixRow2 : Chamber.vec4;           // 16 viewMatrixRow[2]
    projectionMatrixFactors1 : Chamber.vec4; // 16 [0][0] [1][1] [2][2] [2][3]
    projectionMatrixFactors2 : Chamber.vec2; // 8 [0][2] [1][2]
}

eye_init :: (eye : *Eye, extent : Chamber.uvec2) {
    eye.extent = extent;
    eye.viewMatrix = Chamber.look_at_matrix(.{0, 0, 0}, .{1, 0, 0});
    Chamber.infinite_perspective_projection(*eye.projectionMatrix, #run Chamber.to_radians(100.),
                                            cast(float32) extent.width / cast(float32) extent.height, 0.1);
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
    orbit_camera_infinite_perspective_projection(orbitCamera, #run Chamber.to_radians(100), 0.1, false);
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

orbit_camera_rotate_around_target :: (orbitCamera : *OrbitCamera, longitudeAngle : float32, latitudeAngle : float32, $commit := true) {
    relativePosition : Chamber.vec3;
    relativePosition.std = orbitCamera.origin - orbitCamera.target;

    if longitudeAngle < -0.001 || longitudeAngle > 0.001 {
        longitudeDelta := Chamber.rotate_z(relativePosition, longitudeAngle) - relativePosition;
        orbitCamera.origin.std += longitudeDelta;
    }

    if latitudeAngle < -0.001 || latitudeAngle > 0.001 {
        currentLatitudeAngle := asin(relativePosition.z / length(relativePosition));
        if (currentLatitudeAngle + latitudeAngle > PI / 2. - 0.01) {
            latitudeAngle = PI / 2. - 0.01 - currentLatitudeAngle;
        }
        else if (currentLatitudeAngle + latitudeAngle < -PI / 2. + 0.01) {
            latitudeAngle = -PI / 2. + 0.01 - currentLatitudeAngle;
        }

        axis : Chamber.vec3 = ---;
        axis.x = relativePosition.y;
        axis.y = -relativePosition.x;
        axis.z = 0;
        normalize(*axis);

        latitudeDelta := Chamber.rotate(relativePosition, latitudeAngle, axis) - relativePosition;
        orbitCamera.origin.std += latitudeDelta;
    }

    orbitCamera.eye.viewMatrix = Chamber.look_at_matrix(orbitCamera.origin, orbitCamera.target);

    #if commit {
        eye_commit(orbitCamera.eye);
    }
}
