@tool
extends MMGenAnalysis
class_name MMGenHistogram


# Computes the histogram of each channel of its input (256 bins) on the GPU.
# The output is a 256x2 texture: the first row is the cumulative distribution
# of each channel (that maps a value to its rank, used for equalization) and
# the second row the histogram, normalized so its highest bin is 1.


const BINS : int = 256


func get_type() -> String:
	return "histogram"

func get_type_name() -> String:
	return "Histogram"

func get_description() -> String:
	var desc_list : PackedStringArray = PackedStringArray()
	desc_list.push_back(TranslationServer.translate("Histogram"))
	desc_list.push_back(TranslationServer.translate("Computes the histogram and cumulative distribution of each channel of its input"))
	return "\n".join(desc_list)

func get_output_defs(_show_hidden : bool = false) -> Array:
	return [ { type="rgba", shortdesc="Histogram", longdesc="A 256x2 texture: cumulative distribution (top half) and histogram (bottom half) of each channel" } ]

func get_result_size() -> int:
	return 4*BINS

func get_analysis_code() -> String:
	return """for (int c = 0; c < 4; ++c) {
			int bin = clamp(int(value[c]*%d.0), 0, %d);
			atomicAdd(mm_out.mm_results[c*%d+bin], 1);
		}""" % [ BINS, BINS-1, BINS ]

func process_results(results : PackedInt32Array, size : int) -> Image:
	var image : Image = Image.create(BINS, 2, false, Image.FORMAT_RGBAF)
	var total : float = float(size*size)
	var cumulative : Array[float] = [ 0.0, 0.0, 0.0, 0.0 ]
	var highest : Array[int] = [ 1, 1, 1, 1 ]
	for c in 4:
		for b in BINS:
			highest[c] = max(highest[c], results[c*BINS+b])
	for b in BINS:
		var cdf : Color = Color(0, 0, 0, 0)
		var histogram : Color = Color(0, 0, 0, 0)
		for c in 4:
			var count : int = results[c*BINS+b]
			# Values in a bin are mapped to the middle of their rank range
			cdf[c] = (cumulative[c]+0.5*count)/total
			cumulative[c] += count
			histogram[c] = float(count)/float(highest[c])
		image.set_pixel(b, 0, cdf)
		image.set_pixel(b, 1, histogram)
	return image
