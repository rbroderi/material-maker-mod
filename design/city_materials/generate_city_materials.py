"""Generate a ranked list of materials likely to appear in a city-based video game.

Each material is a base surface (for example "Concrete sidewalk slab") combined with a finish
(colour, surface treatment, pattern or cut) and a condition (new, worn, wet, rusted...). Every base,
finish and condition has a weight for how often it shows up in a modern city; the score of a
material is the product of the three, and the list keeps the best scoring ones per category.

Categories:
  hard     rigid manufactured or mineral surfaces: concrete, asphalt, brick, stone, tile, metal,
           glass, rigid plastic, processed wood, plaster and drywall.
  soft     flexible or deformable manufactured surfaces: fabric, carpet, leather, rubber, foam,
           paper and cardboard, plastic film, rope and webbing.
  organic  natural and living surfaces: vegetation, bark and raw wood, natural ground (soil, mud,
           sand, gravel), water, snow and ice, animals, people, food.

Run: python generate_city_materials.py  (writes city_materials.csv next to this file)
"""

import csv
import os

QUOTAS = {"hard": 5000, "soft": 2500, "organic": 2500}

# Each family: category, bases (name=weight 1-10), finishes and conditions (name=weight 0-1).
# Entries are separated by "|". A finish or condition named "-" adds nothing to the name.
FAMILIES = {
    # ----------------------------------------------------------------------------- hard
    "concrete": ("hard",
        "Cast-in-place concrete wall=10|Concrete sidewalk slab=10|Concrete curb=9|Concrete road"
        "=8|Precast concrete panel=8|Concrete block (CMU) wall=8|Polished concrete floor=7|"
        "Concrete pillar=7|Concrete jersey barrier=7|Concrete stairs=7|Concrete parking deck=7|"
        "Concrete ceiling=6|Exposed aggregate concrete=6|Stamped concrete=5|Concrete planter=5|"
        "Terrazzo floor=5|Fiber cement siding=5|Concrete bridge deck=5|Concrete retaining wall=6|"
        "Concrete loading dock=4|Concrete pipe=4|Concrete roof tile=4|Breeze block screen=4|"
        "Concrete bollard=5|Concrete bench=4|Concrete skate ramp=3|Shotcrete=3|"
        "Pervious concrete=3|Concrete tunnel lining=4|Concrete subway platform=6",
        "-=1|broom finish=0.8|smooth troweled=0.8|board-formed=0.45|sandblasted=0.4|"
        "painted gray=0.6|painted white=0.5|painted yellow stripe=0.35|sealed=0.6|"
        "acid-stained=0.3|tactile strip=0.3",
        "clean=1|worn=1|weathered=0.95|dirty=0.95|new=0.9|stained=0.85|wet=0.85|cracked=0.8|"
        "chipped=0.7|graffiti=0.6|oil-stained=0.6|damaged=0.6|water-streaked=0.55|"
        "moss-covered=0.45|efflorescence=0.45|chewing gum spotted=0.45|crumbling=0.4|"
        "snow-dusted=0.4|exposed rebar=0.35|burnt=0.2"),
    "asphalt": ("hard",
        "Asphalt road=10|Asphalt parking lot=9|Asphalt crosswalk=7|Asphalt shingle roof=8|"
        "Asphalt patch=6|Asphalt sidewalk=4|Asphalt bike lane=4|Asphalt alley=6|Asphalt highway=6|"
        "Tar seal coat=4|Chip seal road=3|Rubberized asphalt=3|Asphalt basketball court=4|"
        "Asphalt driveway=5|Tar roof (built-up)=5",
        "-=1|faded gray=0.9|fresh black=0.8|with lane markings=0.8|with manhole cover=0.5|"
        "with storm drain=0.45|with painted symbols=0.4",
        "worn=1|cracked=0.9|wet=0.9|new=0.8|patched=0.8|oil-stained=0.75|alligator-cracked=0.7|"
        "potholed=0.7|puddled=0.7|tire-marked=0.6|dusty=0.6|sealed cracks=0.6|rutted=0.5|"
        "snow-covered=0.45|salt-stained=0.4|litter-strewn=0.4"),
    "brick": ("hard",
        "Red clay brick wall=10|Brick paver=8|Brown brick wall=7|Painted brick wall=7|"
        "Yellow brick wall=5|Reclaimed brick=5|Thin brick veneer=5|White glazed brick=4|"
        "Engineering brick=4|Brick arch=4|Brick chimney=4|Firebrick=3|Brick floor=4|"
        "Brick sidewalk=6|Brick planter=4|Brick column=4|Black brick wall=3|Brick tunnel=3",
        "running bond=1|herringbone=0.6|flemish bond=0.5|english bond=0.5|stack bond=0.5|"
        "with white mortar=0.5|with dark mortar=0.5|recessed mortar=0.5|basketweave=0.4|"
        "soldier course=0.3",
        "worn=1|weathered=1|clean=0.9|dirty=0.9|new=0.8|wet=0.8|soot-stained=0.7|graffiti=0.65|"
        "efflorescence=0.6|spalled=0.6|crumbling mortar=0.6|damaged=0.6|moss-covered=0.5|"
        "painted-over=0.5|peeling paint=0.5|broken=0.5|ivy-covered=0.4|poster-covered=0.4"),
    "stone": ("hard",
        "Granite paver=8|Granite curb=8|Granite countertop=7|Granite facade=6|Marble floor=7|"
        "Marble facade=5|Marble wall cladding=5|Limestone facade=7|Sandstone facade=5|"
        "Slate roof tile=5|Slate paver=4|Flagstone path=5|Cobblestone street=7|Travertine floor=4|"
        "Basalt paver=4|Bluestone paver=4|Quartzite cladding=3|Fieldstone wall=4|"
        "Ashlar masonry=5|Rubble masonry=4|Engineered quartz countertop=6|Granite monument=3|"
        "Marble statue=3|Stone steps=6|Stone fountain=4|Stone retaining wall=5|Crushed stone=5|"
        "River rock landscaping=4|Gravel ballast=4|Stone window sill=4",
        "-=1|rough cut=0.7|polished=0.9|honed=0.8|split-face=0.5|flamed=0.5|tumbled=0.4|"
        "bush-hammered=0.4|gray=0.6|white=0.5|black=0.5|beige=0.5|pink=0.25|veined=0.4",
        "worn=1|weathered=1|clean=0.9|dirty=0.9|wet=0.85|new=0.8|stained=0.7|chipped=0.6|"
        "cracked=0.6|foot-polished=0.5|lichen-covered=0.5|moss-covered=0.5|graffiti=0.5|"
        "pigeon droppings=0.4|snow-dusted=0.35|soot-blackened=0.35"),
    "tile": ("hard",
        "Ceramic floor tile=9|Porcelain floor tile=8|Ceramic wall tile=8|Subway tile=7|"
        "Mosaic tile=5|Hexagon tile=5|Quarry tile=4|Terracotta tile=4|Clay roof tile=6|"
        "Vinyl composition tile=6|Checkerboard tile floor=5|Encaustic cement tile=3|"
        "Glass mosaic tile=3|Tactile warning paving=6|Drop ceiling tile=7|Pool tile=3|"
        "Kitchen backsplash tile=5|Bathroom floor tile=7|Shower tile=6|Metro station wall tile=5|"
        "Porcelain toilet=6|Porcelain sink=6|Enameled bathtub=4|Porcelain urinal=4|"
        "Stoneware dish=3|Ceramic mug=3",
        "white=0.9|gray=0.8|matte=0.8|beige=0.7|glossy=0.7|black=0.6|cream=0.6|blue=0.5|"
        "checkerboard=0.5|patterned=0.5|green=0.4|terracotta red=0.4|yellow=0.3",
        "clean=1|worn=0.95|new=0.9|dirty=0.9|grimy grout=0.8|wet=0.8|cracked=0.7|stained=0.7|"
        "chipped=0.6|missing tiles=0.5|moldy grout=0.5|water-stained=0.5|graffiti=0.35"),
    "ferrous metal": ("hard",
        "Steel I-beam=7|Sheet steel=7|Corrugated steel=7|Galvanized steel=7|Diamond plate steel"
        "=6|Steel door=7|Rolling steel shutter=7|Steel shipping container=6|Chain-link fence=8|"
        "Wrought iron railing=6|Cast iron manhole cover=8|Cast iron storm grate=7|"
        "Cast iron lamppost=6|Cast iron radiator=4|Steel guardrail=7|Steel scaffolding=6|"
        "Steel fire escape=6|Steel grating=6|Expanded metal mesh=5|Perforated steel panel=5|"
        "Rebar=5|Steel rail track=5|Steel dumpster=7|Steel utility pole=5|Steel bollard=6|"
        "Standing seam steel roof=5|Steel HVAC duct=5|Steel pipe=6|Steel bike rack=6|"
        "Steel park bench frame=5|Steel mailbox=4|Steel newspaper box=4|Car body steel=8|"
        "Steel truck bed=4|Steel gas cylinder=3|Steel barrel=4|Steel locker=4|Steel shelving=5|"
        "Stainless steel appliance=7|Stainless steel counter=6|Stainless steel handrail=6|"
        "Stainless steel sink=5|Stainless steel elevator door=6|Steel escalator step=4|"
        "Steel subway car=5|Steel vending machine=5|Steel ATM housing=4|Steel traffic pole=7",
        "painted=0.9|bare=0.8|painted black=0.6|powder-coated=0.7|painted gray=0.6|"
        "galvanized=0.5|brushed=0.6|painted green=0.4|painted red=0.4|painted yellow=0.4|"
        "painted blue=0.35|primed=0.35|polished=0.4",
        "worn=1|scratched=0.9|clean=0.9|dirty=0.9|new=0.85|rusted=0.85|dented=0.7|"
        "peeling paint=0.7|wet=0.7|heavy rust=0.6|graffiti=0.55|sticker-covered=0.5|greasy=0.5|"
        "oxidized=0.5|bird droppings=0.35|snow-dusted=0.3|burnt=0.25"),
    "nonferrous metal": ("hard",
        "Aluminum panel=6|Aluminum window frame=8|Aluminum storefront=7|Aluminum siding=4|"
        "Aluminum street sign=8|Aluminum ladder=3|Aluminum can=5|Aluminum foil=3|"
        "Aluminum composite cladding=5|Aluminum bleacher=3|Aluminum traffic light housing=5|"
        "Anodized aluminum laptop=4|Copper roof=3|Copper pipe=4|Copper gutter=3|"
        "Copper wire=4|Brass door handle=5|Brass fixture=5|Brass railing=3|Brass plaque=3|"
        "Bronze statue=4|Bronze plaque=3|Chrome trim=6|Chrome faucet=6|Chrome bumper=4|"
        "Zinc roof=3|Zinc countertop=2|Lead flashing=3|Pressed tin ceiling=3|Titanium cladding=2|"
        "Gold leaf lettering=2|Gold jewelry=3|Silver jewelry=3|Coin metal=3",
        "-=1|brushed=0.7|polished=0.7|anodized=0.5|satin=0.5|hammered=0.25|lacquered=0.4|"
        "painted=0.5|black anodized=0.35",
        "clean=1|worn=0.95|scratched=0.85|new=0.85|dirty=0.85|tarnished=0.7|fingerprinted=0.6|"
        "dented=0.6|oxidized=0.6|patina=0.45|verdigris=0.4|wet=0.6|graffiti=0.4|"
        "bird droppings=0.3"),
    "glass": ("hard",
        "Window glass=10|Glass curtain wall=8|Shop window glass=8|Glass door=7|"
        "Car windshield=7|Car side window=6|Bus shelter glass=6|Glass railing=5|Skylight=4|"
        "Glass block wall=4|Wired glass=4|Stained glass=3|Mirror=6|Phone screen=6|"
        "LCD display screen=6|Glass bottle=6|Glass jar=3|Drinking glass=4|Glass countertop=2|"
        "Glass shower door=4|Display case glass=4|Glass lamp shade=3|Broken glass shards=5",
        "clear=0.9|tinted=0.7|reflective=0.6|frosted=0.5|green=0.35|brown=0.35|blue tint=0.4|"
        "patterned=0.3|etched=0.3",
        "clean=1|dirty=0.9|smudged=0.8|rain-wet=0.8|new=0.8|streaked=0.7|dusty=0.7|cracked=0.6|"
        "scratched=0.6|condensation=0.5|shattered=0.5|sticker-covered=0.4|fogged=0.4|"
        "graffiti-etched=0.35|frost-covered=0.3"),
    "rigid plastic": ("hard",
        "HDPE trash bin=7|Plastic chair=6|PVC pipe=6|Vinyl siding=6|PVC window frame=6|"
        "Laminate countertop=7|Plastic traffic barrier=6|Plastic traffic cone=7|"
        "Plastic road bollard=5|Acrylic sign=6|Polycarbonate sheet=5|Fiberglass panel=4|"
        "Plastic crate=5|Plastic bottle=6|Plastic electrical box=5|Plastic light switch=6|"
        "Plastic electronics housing=7|Plastic car bumper=6|Car dashboard plastic=6|"
        "Plastic playground slide=4|Composite decking=4|Melamine furniture=5|Epoxy floor=4|"
        "Solid surface countertop=3|Plastic bucket=4|Plastic food container=4|"
        "Plastic shopping cart handle=3|Plastic toy=4|Plastic phone case=4|"
        "Plastic portable toilet=4|Plastic planter=4|Plastic garden furniture=4",
        "white=0.9|black=0.8|gray=0.8|matte=0.7|textured=0.6|glossy=0.6|red=0.5|blue=0.5|"
        "green=0.5|yellow=0.5|orange=0.5|translucent=0.4|wood-grain print=0.3",
        "clean=0.9|new=0.9|worn=0.9|dirty=0.9|scratched=0.85|sun-faded=0.8|cracked=0.6|"
        "yellowed=0.6|wet=0.6|sticker-covered=0.5|graffiti=0.5|chalky=0.4|melted=0.2"),
    "processed wood": ("hard",
        "Oak hardwood floor=8|Maple hardwood floor=6|Walnut hardwood floor=4|Pine floorboards=6|"
        "Cherry hardwood floor=3|Hickory floor=3|Bamboo flooring=3|Parquet floor=4|"
        "Laminate wood flooring=7|Wood planks=7|Plywood=8|OSB board=6|MDF board=5|"
        "Particleboard=4|Wood paneling=5|Wood decking=6|Pressure-treated lumber=5|"
        "Wood fence pickets=6|Wood pallet=7|Railroad tie=4|Wooden telephone pole=5|Wood door=8|"
        "Wood window frame=5|Wood furniture=7|Wood park bench slats=6|Cedar shingles=3|"
        "Wood clapboard siding=5|Boardwalk planks=4|Butcher block counter=4|Wood beam=5|"
        "Shipping crate wood=5|Barn wood=3|Wood bar counter=5|Wood cabinet=6|"
        "Wooden utility spool=3|Plywood boarded window=6",
        "natural=0.9|varnished=0.8|stained dark=0.7|unfinished=0.7|painted white=0.7|"
        "stained light=0.6|oiled=0.6|painted=0.6|lacquered=0.5|whitewashed=0.4|"
        "painted green=0.35|painted red=0.35|charred=0.2",
        "worn=1|weathered=0.95|clean=0.9|new=0.85|scratched=0.85|dirty=0.85|wet=0.7|"
        "water-damaged=0.6|peeling paint=0.6|sun-bleached=0.6|rotting=0.5|splintered=0.5|"
        "graffiti=0.45|moss-covered=0.4|warped=0.4|termite-damaged=0.3|burnt=0.3"),
    "plaster and drywall": ("hard",
        "Painted drywall=10|Plaster wall=7|Exterior stucco=8|Smooth plaster ceiling=6|"
        "Popcorn ceiling=3|Venetian plaster=2|EIFS facade=4|Textured wall=6|Gypsum board=5|"
        "Lime plaster=3|Painted concrete block=6|Painted metal door frame=5|"
        "Painted baseboard=5|Painted crown molding=3|Painted stairwell wall=5|Hospital wall=3|"
        "School hallway wall=4|Office wall=6|Apartment wall=7|Painted pipe=3",
        "white=0.9|off-white=0.8|matte=0.7|beige=0.7|gray=0.7|eggshell=0.6|textured=0.6|"
        "orange-peel=0.5|knockdown=0.4|light blue=0.4|pastel green=0.4|bold color=0.4|"
        "glossy=0.4|two-tone=0.35|pink stucco=0.25|terracotta stucco=0.3",
        "clean=1|new=0.85|scuffed=0.85|dirty=0.8|stained=0.7|water-stained=0.65|"
        "peeling paint=0.65|cracked=0.6|graffiti=0.6|poster-covered=0.5|holes=0.5|moldy=0.5|"
        "smoke-stained=0.4|crumbling=0.35|bullet holes=0.15"),
    # ----------------------------------------------------------------------------- soft
    "fabric": ("soft",
        "Cotton=9|Denim=8|Polyester=8|Nylon=6|Wool=5|Linen=4|Silk=3|Canvas=6|Burlap=3|Fleece=5|"
        "Velvet=3|Corduroy=3|Jersey knit=6|Spandex=3|Flannel=4|Tweed=2|Satin=3|Chiffon=2|"
        "Waterproof shell fabric=4|Reflective safety vest fabric=4|Upholstery fabric=7|"
        "Curtain fabric=6|Awning canvas=5|Flag fabric=4|Tent nylon=3|Mesh fabric=5|Terry towel=4|"
        "Bedsheet=5|Quilted fabric=3|Felt=3|Microfiber=4|Lace=2|Chenille=2|Uniform twill=4|"
        "Hoodie knit=6|T-shirt cotton=8|Suit wool=4|Tablecloth=4|Sofa fabric=7|"
        "Office chair mesh=5|Car seat fabric=6|Car headliner=4|Mattress ticking=4|"
        "Sleeping bag nylon=2|Backpack nylon=5|Umbrella canopy=4|Banner fabric=4",
        "black=0.9|gray=0.8|white=0.8|navy=0.7|blue=0.7|khaki=0.6|red=0.6|brown=0.5|green=0.5|"
        "beige=0.5|striped=0.5|plaid=0.5|printed=0.5|heathered=0.4|yellow=0.35|pink=0.35|"
        "floral=0.3|camouflage=0.2|high-visibility orange=0.3",
        "new=0.9|clean=0.9|worn=0.95|wrinkled=0.8|faded=0.8|dirty=0.85|stained=0.75|wet=0.7|"
        "torn=0.6|frayed=0.6|dusty=0.6|pilled=0.5|muddy=0.45|threadbare=0.4|bloodstained=0.25|"
        "burnt=0.2"),
    "carpet": ("soft",
        "Commercial carpet tile=8|Loop pile carpet=6|Cut pile carpet=6|Office carpet=7|"
        "Hotel corridor carpet=5|Berber carpet=3|Shag rug=3|Persian rug=4|Area rug=6|Runner rug=4|"
        "Rubber-backed doormat=6|Coir doormat=4|Car floor mat carpet=5|Stair carpet=4|"
        "Cinema carpet=3|Casino carpet=2|Bath mat=3|Felt underlay=2",
        "gray=0.9|beige=0.8|patterned=0.7|blue=0.6|brown=0.6|red=0.5|black=0.5|green=0.4|"
        "striped=0.4|burgundy=0.4",
        "clean=0.9|worn=0.95|new=0.85|dirty=0.85|stained=0.8|matted=0.7|wet=0.6|threadbare=0.5|"
        "frayed edges=0.45|moldy=0.3|burnt=0.25|gum-spotted=0.35"),
    "leather": ("soft",
        "Leather=8|Faux leather=7|Suede=4|Patent leather=3|Nubuck=2|Vinyl upholstery=7|"
        "Car seat leather=6|Leather sofa=6|Leather jacket=6|Leather shoe=7|Leather boot=5|"
        "Leather bag=5|Leather belt=5|Leather wallet=4|Saddle leather=2|Bar stool vinyl=5|"
        "Diner booth vinyl=5|Office chair vinyl=5|Baseball glove leather=2|Sports ball leather=3",
        "black=0.9|brown=0.9|tan=0.7|smooth=0.8|pebbled=0.6|gray=0.5|oxblood=0.5|tufted=0.4|"
        "quilted=0.4|perforated=0.4|red=0.4|white=0.4|two-tone=0.3",
        "clean=0.9|worn=0.95|new=0.85|scuffed=0.8|cracked=0.75|creased=0.7|faded=0.7|"
        "stained=0.6|torn=0.5|wet=0.5|peeling=0.45|duct-taped=0.3"),
    "rubber": ("soft",
        "Car tire=9|Bike tire=5|Rubber floor mat=6|Gym rubber flooring=4|Rubber hose=4|"
        "Rubber door seal=4|Rubber boot=3|Conveyor belt=3|Rubber stair tread=5|"
        "Rubber speed bump=5|EPDM roof membrane=4|Neoprene=3|Silicone=3|Latex glove=3|"
        "Rubber gasket=3|Playground rubber surface=5|Rubber mulch=3|Running track=4|"
        "Shoe sole rubber=6|Rubber wheel=4|Rubber bumper guard=3|Escalator handrail=4",
        "black=0.95|smooth=0.7|treaded=0.6|ribbed=0.6|gray=0.6|studded=0.5|red=0.4|blue=0.3|"
        "green=0.3|terracotta red=0.3",
        "worn=1|dirty=0.9|new=0.85|clean=0.8|cracked=0.75|dusty=0.7|wet=0.7|muddy=0.6|"
        "bald=0.4|sun-cracked=0.45|melted=0.2|shredded=0.3"),
    "foam": ("soft",
        "Polyurethane foam=6|Memory foam=4|EVA foam=4|Styrofoam (EPS)=5|Foam packaging=5|"
        "Seat cushion foam=5|Acoustic foam panel=4|Spray foam insulation=4|Foam gym mat=4|"
        "Foam mattress=4|Pool noodle=2|Foam earplug=1|Foam cup=4|Foam takeout box=5",
        "white=0.8|gray=0.7|yellow=0.6|black=0.6|blue=0.4|pink=0.3",
        "new=0.9|worn=0.9|dirty=0.85|compressed=0.6|crumbling=0.6|torn=0.6|yellowed=0.55|"
        "wet=0.5|moldy=0.3|burnt=0.2"),
    "paper": ("soft",
        "Corrugated cardboard=9|Cardboard box=9|Newspaper=7|Office paper=7|Poster paper=7|"
        "Wallpaper=6|Kraft paper=4|Paper bag=6|Tissue paper=3|Receipt paper=4|Glossy magazine=5|"
        "Book pages=5|Paper cup=6|Paper takeout container=5|Vinyl sticker=6|Flyer=6|"
        "Cardboard sign=5|Toilet paper=4|Paper towel=4|Envelope=4|Paper money=4|"
        "Pizza box=6|Egg carton=3|Paper ticket=3|Paper map=2|Cigarette pack=4|Paper napkin=4",
        "-=1|printed=0.8|white=0.7|brown=0.7|colored=0.5|glossy=0.4|handwritten=0.3|lined=0.3",
        "crumpled=0.85|new=0.8|torn=0.8|dirty=0.8|soggy=0.75|clean=0.7|stained=0.7|faded=0.7|"
        "yellowed=0.6|water-damaged=0.6|flattened=0.6|peeling=0.6|moldy=0.3|burnt=0.3"),
    "plastic film": ("soft",
        "Plastic bag=8|Trash bag=8|Bubble wrap=4|Shrink wrap=5|Plastic tarp=6|Vinyl banner=6|"
        "PVC strip curtain=4|Shower curtain=4|Cling film=3|Inflatable vinyl=3|Plastic sheeting=5|"
        "Raincoat=4|Vinyl sheet flooring=6|Linoleum floor=5|Cushioned vinyl floor=4|"
        "Snack wrapper=5|Plastic packaging=6|Construction safety netting=4|"
        "Caution tape=5|Window film=3",
        "black=0.8|clear=0.7|white=0.7|blue=0.6|translucent=0.5|printed=0.5|green=0.4|"
        "yellow=0.4|orange=0.35",
        "crumpled=0.85|dirty=0.85|new=0.8|torn=0.75|wet=0.7|faded=0.6|ripped=0.5|stretched=0.5|"
        "sun-degraded=0.5|melted=0.15"),
    "rope and webbing": ("soft",
        "Nylon rope=5|Polypropylene rope=4|Manila rope=3|Bungee cord=3|Cargo net=3|"
        "Fishing net=2|Sports net=4|Shoelace=4|Electrical cable insulation=7|Power cord=6|"
        "Extension cord=5|Woven strap=4|Seatbelt webbing=5|Ratchet strap=3|Hammock=1|"
        "Climbing rope=2|Twine=3|Lanyard=3|Velcro=3|Zipper tape=3",
        "black=0.9|white=0.7|gray=0.7|orange=0.5|yellow=0.5|blue=0.5|red=0.5|braided=0.5|"
        "twisted=0.5|green=0.4",
        "new=0.85|worn=0.95|dirty=0.85|frayed=0.75|tangled=0.6|wet=0.6|knotted=0.5|"
        "cut=0.45|sun-faded=0.45|burnt=0.15"),
    # -------------------------------------------------------------------------- organic
    "vegetation": ("organic",
        "Mowed lawn grass=10|Overgrown grass=7|Dry grass=7|Weeds in pavement cracks=8|Moss=7|"
        "Lichen=5|Ivy=6|Hedge leaves=7|Shrub leaves=7|Flower bed=6|Clover=4|Ferns=3|"
        "Leaf litter=8|Green leaves=7|Autumn leaves=6|Pine needles=4|Tree roots=5|Branches=5|"
        "Twigs=4|Roses=3|Tulips=2|Petunias=2|Sunflowers=1|Cactus=2|Succulents=3|Bamboo=3|"
        "Palm fronds=4|Algae=4|Mushrooms=3|Bracket fungus=2|Vines=5|Reeds=3|Potted plant=6|"
        "Houseplant leaves=5|Sod rolls=2|Street tree canopy=7|Wildflowers=3|Dandelions=4|"
        "Rooftop garden plants=3|Vegetable garden=3",
        "-=1|green=0.6|yellow-green=0.4|dark green=0.5|variegated=0.2|flowering=0.3",
        "healthy=1|fresh=0.9|lush=0.8|dry=0.8|wet=0.8|autumn=0.7|wilted=0.6|dead=0.6|"
        "overgrown=0.6|trampled=0.55|dewy=0.5|muddy=0.5|dusty=0.5|snow-covered=0.45|"
        "frosted=0.4|diseased=0.3|burnt=0.2"),
    "bark and raw wood": ("organic",
        "Oak bark=6|Pine bark=5|Birch bark=4|Plane tree bark=6|Maple bark=5|Palm trunk=4|"
        "Cherry tree bark=3|Elm bark=3|Linden bark=3|Ginkgo bark=2|Log=4|Firewood=3|"
        "Tree stump=4|Driftwood=2|Sawdust=3|Wood shavings=3|Wood chip mulch=7|Bark mulch=6|"
        "Cork=3|Wicker=4|Rattan=3|Jute=3|Coconut husk=1|Straw=3|Hay bale=2|Bamboo pole=3",
        "-=1|dark=0.5|light=0.5|reddish=0.3|gray=0.4",
        "dry=0.9|weathered=0.9|fresh=0.8|wet=0.8|mossy=0.6|lichen-covered=0.5|cut=0.5|"
        "rotting=0.5|carved initials=0.3|snow-covered=0.4|burnt=0.25|peeling=0.45|"
        "insect-damaged=0.3"),
    "natural ground": ("organic",
        "Dirt path=8|Packed earth=7|Topsoil=6|Clay soil=5|Mud=8|Sand=7|Beach sand=4|"
        "Playground sand=4|Loose gravel=8|Pea gravel=5|Decomposed granite path=4|Dust=7|"
        "Ash=3|Silt=3|Peat=2|Dried cracked mud=4|Construction site dirt=6|Dog park dirt=3|"
        "Tree pit soil=6|Planter soil=6|Garden bed soil=5|Riverbank mud=4|Rubble and dirt=5|"
        "Compost=3|Potting soil=4|Cinder track=2",
        "-=1|dark brown=0.6|light brown=0.6|reddish=0.4|gray=0.5|yellow=0.3|black=0.3",
        "dry=0.95|wet=0.9|damp=0.85|compacted=0.75|footprinted=0.7|tire-tracked=0.65|"
        "puddled=0.6|loose=0.6|littered=0.5|rippled=0.4|frozen=0.4|snow-dusted=0.4|"
        "oil-stained=0.35|weedy=0.5"),
    "water and ice": ("organic",
        "Puddle water=9|Rain on pavement=8|River water=5|Pond water=4|Fountain water=5|"
        "Canal water=4|Harbor seawater=4|Pool water=4|Gutter runoff=6|Sewer water=3|"
        "Fresh snow=6|Packed snow=6|Slush=6|Dirty snow=6|Snowbank=5|Ice=5|Black ice=4|Frost=5|"
        "Icicles=3|Condensation droplets=4|Spilled soda=4|Spilled coffee=4|Spilled beer=3|"
        "Blood=4|Vomit=2|Motor oil puddle=4|Mud puddle=5|Foam on water=2",
        "-=1|clear=0.6|murky=0.6|muddy=0.5|green-tinted=0.3|oily sheen=0.4",
        "still=0.9|rippled=0.8|flowing=0.6|shallow=0.8|splashing=0.5|frozen over=0.4|"
        "littered=0.45|stagnant=0.5|fresh=0.7|dried=0.5"),
    "animal": ("organic",
        "Pigeon feathers=5|Bird droppings=7|Dog fur=6|Cat fur=5|Horse hair=2|Rat fur=3|"
        "Squirrel fur=2|Insect wing=2|Cockroach shell=2|Fish scales=3|Snake skin=1|Bone=3|"
        "Eggshell=3|Spider web=4|Honeycomb=1|Seashell=2|Feathers=4|Raw wool=1|Animal hide=2|"
        "Dog nose=2|Paw pad=2|Hoof=1|Shellfish shell=2|Crab shell=2",
        "-=1|black=0.6|white=0.6|brown=0.6|gray=0.6|spotted=0.4|tabby=0.3|ginger=0.3",
        "clean=0.9|dirty=0.8|wet=0.7|matted=0.5|shedding=0.4|dry=0.6|dusty=0.5|fresh=0.6"),
    "human skin": ("organic",
        "Skin, very light tone=7|Skin, light tone=8|Skin, medium tone=8|Skin, tan tone=8|"
        "Skin, brown tone=8|Skin, dark tone=8|Skin, deep tone=7",
        "face=0.9|hands=0.8|arms=0.6|young adult=0.6|adult=0.7|elderly=0.5|child=0.4",
        "clean=1|sweaty=0.6|wet=0.6|dirty=0.55|freckled=0.5|with makeup=0.5|wrinkled=0.45|"
        "tattooed=0.45|sunburned=0.35|scarred=0.3|bruised=0.25|bloody=0.2"),
    "human hair": ("organic",
        "Straight hair=7|Wavy hair=6|Curly hair=6|Coily hair=6|Braided hair=4|Locs=3|Beard=5|"
        "Stubble=5|Eyebrows=3",
        "black=0.8|dark brown=0.8|brown=0.6|blonde=0.5|gray=0.45|red=0.3|dyed=0.25",
        "clean=1|wet=0.6|messy=0.6|styled=0.5|dirty=0.45|oily=0.4|sweaty=0.4"),
    "human features": ("organic",
        "Eyes=5|Lips=4|Teeth=4|Fingernails=4|Bald scalp=3",
        "-=1|light=0.5|dark=0.5|brown=0.5|blue=0.3|green=0.2|painted=0.25",
        "clean=1|wet=0.6|dirty=0.4|bloodshot=0.25|stained=0.3|chipped=0.2"),
    "food": ("organic",
        "Bread=6|Pizza=7|Burger=6|French fries=6|Hot dog=5|Sandwich=5|Taco=4|Pretzel=3|Donut=5|"
        "Cake=4|Chocolate=4|Ice cream=4|Popcorn=3|Candy=4|Apple=5|Banana=5|Orange=5|Lemon=3|"
        "Watermelon=2|Strawberry=3|Grapes=3|Lettuce=4|Tomato=5|Carrot=3|Potato=3|Onion=3|"
        "Raw meat=4|Cooked meat=4|Raw fish=3|Cheese=4|Eggs=3|Rice=4|Noodles=4|Sushi=3|"
        "Coffee beans=3|Nuts=3|Cereal=3|Food waste=6|Banana peel=4|Cigarette butt=6|"
        "Chewing gum=5",
        "-=1|cooked=0.6|raw=0.5|sliced=0.5|whole=0.6|packaged=0.4",
        "fresh=0.9|ripe=0.8|half-eaten=0.6|spilled=0.55|rotten=0.5|moldy=0.5|dried=0.4|"
        "wet=0.4|frozen=0.3|burnt=0.3|squashed=0.45"),
}

NO_WORD = {"-"}


def parse(spec: str) -> list:
    out = []
    for item in spec.split("|"):
        name, _, w = item.strip().rpartition("=")
        out.append((name.strip(), float(w)))
    return out


def build() -> dict:
    by_cat = {c: {} for c in QUOTAS}
    for family, (cat, bases, finishes, conditions) in FAMILIES.items():
        f_list, c_list = parse(finishes), parse(conditions)
        for base, bw in parse(bases):
            for fin, fw in f_list:
                for cond, cw in c_list:
                    parts = [base] + [p for p in (fin, cond) if p not in NO_WORD]
                    name = ", ".join(parts)
                    score = bw / 10.0 * fw * cw
                    row = (score, name, family, base, "" if fin in NO_WORD else fin, cond)
                    old = by_cat[cat].get(name)
                    if old is None or old[0] < score:
                        by_cat[cat][name] = row
    return by_cat


def select(rows: list, quota: int) -> list:
    rows = sorted(rows, key=lambda r: (-r[0], r[1]))
    # Every base gets at least its best variant, then the rest fill by score.
    chosen, seen_base = [], set()
    for r in rows:
        if r[3] not in seen_base:
            seen_base.add(r[3])
            chosen.append(r)
    picked = set(r[1] for r in chosen)
    for r in rows:
        if len(chosen) >= quota:
            break
        if r[1] not in picked:
            chosen.append(r)
            picked.add(r[1])
    if len(chosen) < quota:
        raise SystemExit("only %d candidates for a quota of %d" % (len(chosen), quota))
    return sorted(chosen[:quota], key=lambda r: (-r[0], r[1]))


def main() -> None:
    by_cat = build()
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "city_materials.csv")
    with open(out, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerow(["category", "rank", "material", "family", "base", "finish", "condition",
                    "score"])
        for cat, quota in QUOTAS.items():
            for i, (score, name, family, base, fin, cond) in enumerate(
                    select(list(by_cat[cat].values()), quota), 1):
                w.writerow([cat, i, name, family, base, fin, cond, "%.4f" % score])
    for cat in QUOTAS:
        print(cat, len(by_cat[cat]), "candidates")
    print("wrote", out)


if __name__ == "__main__":
    main()
