import { create } from 'zustand';

export interface BeadPanelItem {
  id: string;
  title: string;
  status: string;
  issue_type?: string;
  labels?: string[];
  description?: string;
  assignee?: string | null;
  created_at?: string;
  updated_at?: string;
  closed_at?: string;
  metadata?: Record<string, any>;
}

interface DashState {
  city: string;
  rig: string;
  setRig: (r: string) => void;
  setCity: (c: string) => void;
  selectedBead: string | null;
  setSelectedBead: (id: string | null) => void;
  beadListPanel: { title: string; items: BeadPanelItem[] } | null;
  setBeadListPanel: (panel: { title: string; items: BeadPanelItem[] } | null) => void;
  // Open-intent: when set, the artifact panel (after loading the bead's run dir)
  // auto-opens this filename with tail mode on. Cleared once consumed.
  openFileIntent: { beadId: string; preferLog?: boolean } | null;
  setOpenFileIntent: (intent: { beadId: string; preferLog?: boolean } | null) => void;
}

export const useDash = create<DashState>((set) => ({
  city: 'bright-lights',
  rig: 'park-manip',
  setRig: (r) => set({ rig: r }),
  setCity: (c) => set({ city: c }),
  selectedBead: null,
  setSelectedBead: (id) => set({ selectedBead: id, beadListPanel: null }),
  beadListPanel: null,
  setBeadListPanel: (panel) => set({ beadListPanel: panel, selectedBead: null }),
  openFileIntent: null,
  setOpenFileIntent: (intent) => set({ openFileIntent: intent }),
}));
