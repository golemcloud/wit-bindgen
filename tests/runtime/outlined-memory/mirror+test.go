package export_test_outlined_memory_mirror

import api "wit_component/export_test_outlined_memory_api"

func Echo(values []api.Batch) []api.Batch { return values }
