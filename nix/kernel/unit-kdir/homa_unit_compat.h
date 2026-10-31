/* Force-included when building the unit harness against a newer kernel than
 * the vendored test/ rhashtable sources were taken from.
 */
#ifndef kvmalloc_node_noprof
#define kvmalloc_node_noprof(_size, _flags, _node) \
	kvmalloc_node_align_noprof(_size, 1, _flags, _node)
#endif
