// 由 tools/export_stations.py 生成：2105 个电台，静态编译进 HAP，无需运行时联网取列表。
import { Station } from './Station';
import { STATION_PART_1 } from './data/StationDataPart1';
import { STATION_PART_2 } from './data/StationDataPart2';
import { STATION_PART_3 } from './data/StationDataPart3';
import { STATION_PART_4 } from './data/StationDataPart4';

export const ALL_STATIONS: Station[] = STATION_PART_1
  .concat(STATION_PART_2)
  .concat(STATION_PART_3)
  .concat(STATION_PART_4);
