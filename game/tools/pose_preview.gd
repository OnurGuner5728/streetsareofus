extends SceneTree
## Debug: renders the base bodies in a few baked poses to a PNG.
##   "$GODOT" --path game -s tools/pose_preview.gd -- out.png [clip,clip,...] [time]

var _out := ""
var _frames := 0


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	_out = args[0] if args.size() > 0 else "user://pose.png"
	var clips := (args[1] if args.size() > 1 else "idle,walk,jog,sprint,sit,talk").split(",")
	var at := float(args[2]) if args.size() > 2 else 0.3
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS, true)
	DisplayServer.window_set_position(Vector2i(DisplayServer.screen_get_size().x + 50, 50))
	var stage := Node3D.new()
	root.add_child(stage)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("2a3440")
	env.ambient_light_color = Color("aab4c8")
	env.ambient_light_energy = 0.8
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	var we := WorldEnvironment.new()
	we.environment = env
	stage.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-40, 20, 0)
	sun.light_energy = 1.5
	sun.shadow_enabled = true
	stage.add_child(sun)
	var i := 0
	for clip in clips:
		var body := "male" if i % 2 == 0 else "female"
		var scene: Node3D = load("res://assets/characters/Superhero_%s_FullBody.gltf" % body.capitalize()).instantiate()
		stage.add_child(scene)
		scene.position = Vector3(-((clips.size() - 1) * 0.6) + i * 1.2, 0, 0)
		scene.rotation.y = 0.3 * (i % 3 - 1)
		var ap := AnimationPlayer.new()
		scene.add_child(ap)
		ap.add_animation_library("", load("res://assets/characters/anims_%s.res" % body))
		ap.play(clip)
		ap.seek(at, true)
		ap.pause()
		i += 1
	var cam := Camera3D.new()
	cam.position = Vector3(0, 1.0, 1.2 + clips.size() * 0.75)
	cam.fov = 45
	stage.add_child(cam)


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 12:
		root.get_viewport().get_texture().get_image().save_png(_out)
		print("saved ", _out)
		return true
	return false
