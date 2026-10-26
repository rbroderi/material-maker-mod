extends RefCounted
class_name MMOpenPBRPreview


# An approximation of the OpenPBR surface model for the 3D preview. Godot does
# not let material shaders replace its whole lighting model, but a light()
# function replaces the direct lighting: this one layers a coat (IOR 1.6) over
# fuzz (sheen) over the base (GGX specular, anisotropic, with metals tinted by
# the albedo, and diffuse or thin walled transmission). Ambient and reflected
# light still use Godot's model (with its clearcoat).
#
# The preview shader of the Material node is modified: its coat, anisotropy,
# sheen and transmission values are also written to varyings read by light().


const SETTING : String = "ui_3d_preview_openpbr"

const VARYINGS : String = """
varying float mm_openpbr_coat;
varying float mm_openpbr_coat_roughness;
varying float mm_openpbr_anisotropy;
varying float mm_openpbr_fuzz;
varying vec3 mm_openpbr_transmission;
varying vec3 mm_openpbr_tangent;
varying vec3 mm_openpbr_binormal;
"""

const LIGHT : String = """
float mm_openpbr_ggx(float NdotH, float TdotH, float BdotH, float ax, float ay) {
	float d = max(TdotH*TdotH/(ax*ax)+BdotH*BdotH/(ay*ay)+NdotH*NdotH, 0.0001);
	return 1.0/(PI*ax*ay*d*d);
}

float mm_openpbr_ggx_isotropic(float NdotH, float a) {
	float a2 = a*a;
	float d = NdotH*NdotH*(a2-1.0)+1.0;
	return a2/(PI*d*d);
}

float mm_openpbr_smith(float NdotV, float NdotL, float a) {
	float a2 = a*a;
	float gv = NdotL*sqrt(NdotV*NdotV*(1.0-a2)+a2);
	float gl = NdotV*sqrt(NdotL*NdotL*(1.0-a2)+a2);
	return 0.5/max(gv+gl, 0.00001);
}

float mm_openpbr_charlie(float NdotH, float roughness) {
	float inverse_roughness = 1.0/max(roughness, 0.001);
	return (2.0+inverse_roughness)*pow(max(1.0-NdotH*NdotH, 0.0), 0.5*inverse_roughness)/(2.0*PI);
}

void light() {
	vec3 H = normalize(VIEW+LIGHT);
	float NdotL = dot(NORMAL, LIGHT);
	float cNdotL = max(NdotL, 0.0);
	float NdotV = max(dot(NORMAL, VIEW), 0.0001);
	float NdotH = max(dot(NORMAL, H), 0.0);
	float VdotH = max(dot(VIEW, H), 0.0);
	float fresnel = pow(1.0-VdotH, 5.0);
	// LIGHT_COLOR includes PI, as physically based models divide by PI
	vec3 radiance = LIGHT_COLOR*ATTENUATION/PI;
	// Coat: a dielectric layer (IOR 1.6) that hides what is below it
	float coat = clamp(mm_openpbr_coat, 0.0, 1.0);
	float coat_a = max(mm_openpbr_coat_roughness*mm_openpbr_coat_roughness, 0.002);
	float coat_fresnel = 0.053+0.947*fresnel;
	float coat_specular = mm_openpbr_ggx_isotropic(NdotH, coat_a)*mm_openpbr_smith(NdotV, cNdotL, coat_a)*coat_fresnel;
	float below_coat = 1.0-coat*coat_fresnel;
	// Fuzz: retro-reflective sheen over the base
	float fuzz = clamp(mm_openpbr_fuzz, 0.0, 1.0);
	float fuzz_specular = mm_openpbr_charlie(NdotH, 0.5)/(4.0*(cNdotL+NdotV-cNdotL*NdotV)+0.0001);
	float below_fuzz = 1.0-0.3*fuzz;
	// Base: anisotropic GGX, dielectric (F0 0.04) or metal (tinted by the albedo)
	float a = max(ROUGHNESS*ROUGHNESS, 0.002);
	float anisotropy = clamp(mm_openpbr_anisotropy, 0.0, 0.95);
	float ax = max(a*(1.0+anisotropy), 0.002);
	float ay = max(a*(1.0-anisotropy), 0.002);
	vec3 f0 = mix(vec3(0.04), ALBEDO, METALLIC);
	// Tangent frame around the (normal mapped) shading normal
	vec3 tangent = mm_openpbr_tangent-NORMAL*dot(NORMAL, mm_openpbr_tangent);
	tangent = dot(tangent, tangent) > 0.000001 ? normalize(tangent) : normalize(cross(NORMAL, vec3(0.0, 1.0, 0.01)));
	vec3 binormal = cross(NORMAL, tangent)*(dot(cross(NORMAL, tangent), mm_openpbr_binormal) < 0.0 ? -1.0 : 1.0);
	vec3 base_specular = mm_openpbr_ggx(NdotH, dot(tangent, H), dot(binormal, H), ax, ay)*mm_openpbr_smith(NdotV, cNdotL, a)*(f0+(vec3(1.0)-f0)*fresnel);
	// Diffuse (Godot multiplies it by the albedo and 1-metallic), or light
	// passing through a thin wall from behind
	float transmission = clamp(max(max(mm_openpbr_transmission.r, mm_openpbr_transmission.g), mm_openpbr_transmission.b), 0.0, 1.0);
	float diffuse = (1.0-transmission)*cNdotL*(1.0-(0.04+0.96*fresnel))+transmission*max(-NdotL, 0.0);
	DIFFUSE_LIGHT += radiance*below_coat*below_fuzz*diffuse;
	// Specular reflections only for lights in front of the surface (this
	// also avoids 0*infinity at grazing angles)
	if (NdotL > 0.0) {
		SPECULAR_LIGHT += radiance*cNdotL*SPECULAR_AMOUNT*(below_coat*below_fuzz*base_specular+vec3(coat*coat_specular+fuzz*fuzz_specular));
	}
}
"""

## The values written to varyings, from the preview shader's assignments
const ASSIGNMENTS : Dictionary = {
	"CLEARCOAT": "mm_openpbr_coat",
	"CLEARCOAT_ROUGHNESS": "mm_openpbr_coat_roughness",
	"ANISOTROPY": "mm_openpbr_anisotropy",
	"RIM": "mm_openpbr_fuzz",
	"BACKLIGHT": "mm_openpbr_transmission"
}

static func is_enabled() -> bool:
	return mm_globals.has_config(SETTING) and mm_globals.get_config(SETTING)

## Modifies a Material node's (processed) preview shader. Shaders that do not
## set the coat, anisotropy, sheen and transmission are not modified.
static func apply(code : String) -> String:
	var lines : PackedStringArray = code.split("\n")
	var found : int = 0
	var rv : PackedStringArray = PackedStringArray()
	for l in lines:
		if l.begins_with("void vertex()"):
			rv.append(VARYINGS)
		rv.append(l)
		var stripped : String = l.strip_edges()
		for builtin in ASSIGNMENTS.keys():
			if stripped.begins_with(builtin+" = ") and stripped.ends_with(";"):
				rv.append("\t%s = %s" % [ ASSIGNMENTS[builtin], stripped.substr(builtin.length()+3) ])
				found += 1
				if builtin == "CLEARCOAT":
					rv.append("\tmm_openpbr_tangent = TANGENT;")
					rv.append("\tmm_openpbr_binormal = BINORMAL;")
	if found < ASSIGNMENTS.size() or not code.contains("void vertex()"):
		return code
	return "\n".join(rv)+"\n"+LIGHT
