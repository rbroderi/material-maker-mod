Normal Combine node
~~~~~~~~~~~~~~~~~~~

The **Normal Combine** node: combines a detail normal map with a base normal map, with the Reoriented Normal Mapping (RNM), Whiteout or UDN methods.

Inputs
++++++

* **Base**: The base normal map
* **Detail**: The detail normal map, applied over the base

Outputs
+++++++

* **Output**: The combined normal map

Parameters
++++++++++

* **Mode**: RNM reorients the detail along the base (most accurate), Whiteout and UDN are cheaper approximations
* **Strength**: The strength of the detail normal map
