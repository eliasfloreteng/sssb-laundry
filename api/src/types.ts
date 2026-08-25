export const STOCKHOLM_TZ = "Europe/Stockholm";

export type GroupSlotStatus = "bookable" | "own" | "unavailable";

export interface BookingGroup {
  id: number;
  location: string | null;
  name: string;
}

export interface GroupSlot {
  groupId: number;
  startAt: string;
  endAt: string;
  localDate: string;
  startTime: string;
  endTime: string;
  spansMidnight: boolean;
  status: GroupSlotStatus;
  bookUrl?: string;
  unbookUrl?: string;
  bookingId?: number;
  passNo?: number;
  passDate?: string;
}

export interface CanonicalGroupState {
  groupId: number;
  status: GroupSlotStatus;
  canBook: boolean;
  canCancel: boolean;
}

export interface CanonicalTimeslot {
  id: string;
  startAt: string;
  endAt: string;
  localDate: string;
  startTime: string;
  endTime: string;
  spansMidnight: boolean;
  groups: CanonicalGroupState[];
}

export interface WeekWindow {
  fromDate: string;
  toDate: string;
  timezone: string;
}

export interface TimeslotsResponse {
  week: WeekWindow;
  groups: BookingGroup[];
  timeslots: CanonicalTimeslot[];
}

export interface GroupActionResult {
  groupId: number;
  status: string;
  message?: string;
  error?: {
    code: string;
    message: string;
    details?: unknown;
  };
}

export interface ActionResponse {
  timeslotId: string;
  results: GroupActionResult[];
  overallStatus: "success" | "partial_success" | "failed";
}
