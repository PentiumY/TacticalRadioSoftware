import { z } from "zod";

export const Vector3Schema = z.object({
  x: z.number(),
  y: z.number(),
  z: z.number()
});

export type Vector3 = z.infer<typeof Vector3Schema>;

export const PlayerRadioStateSchema = z.object({
  robloxUserId: z.number().int().positive(),
  username: z.string().optional(),
  displayName: z.string().optional(),
  
  placeId: z.number().int().positive(),
  jobId: z.string().min(1),
  
  position: Vector3Schema,
  lookVector: Vector3Schema,
  
  frequency: z.string().min(1),
  isPtt: z.boolean(),
  
  team: z.string().optional(),
  squad: z.string().optional(),
  radioId: z.string().optional(),
  
  updatedAtMs: z.number().int().nonnegative()
});

export type PlayerRadioState = z.infer<typeof PlayerRadioStateSchema>;

export const RobloxStateUpdateSchema = z.object({
  placeId: z.number().int().positive(),
  jobId: z.string().min(1),
  
  players: z.array(
    z.object({
      robloxUserId: z.number().int().positive(),
      username: z.string().optional(),
      displayName: z.string().optional(),
      
      position: Vector3Schema,
      lookVector: Vector3Schema,
      
      frequency: z.string().min(1),
      isPtt: z.boolean(),
      
      team: z.string().optional(),
      squad: z.string().optional(),
      radioId: z.string().optional()
    })
  )
});

export type RobloxStateUpdate = z.infer<typeof RobloxStateUpdateSchema>;

export const TxStartRequestSchema = z.object({
  placeId: z.number().int().positive(),
  jobId: z.string().min(1),
  frequency: z.string().min(1),
  robloxUserId: z.number().int().positive(),
  radioId: z.string().optional()
});

export type TxStartRequest = z.infer<typeof TxStartRequestSchema>;

export const TxHeartbeatRequestSchema = z.object({
  placeId: z.number().int().positive(),
  jobId: z.string().min(1),
  frequency: z.string().min(1),
  robloxUserId: z.number().int().positive(),
  token: z.string().min(1)
});

export type TxHeartbeatRequest = z.infer<typeof TxHeartbeatRequestSchema>;

export const TxStopRequestSchema = TxHeartbeatRequestSchema;

export type TxStopRequest = z.infer<typeof TxStopRequestSchema>;

export const TxLockSchema = z.object({
  placeId: z.number().int().positive(),
  jobId: z.string().min(1),
  frequency: z.string().min(1),
  
  ownerRobloxUserId: z.number().int().positive(),
  radioId: z.string().optional(),
  
  token: z.string().min(1),
  
  grantedAtMs: z.number().int().nonnegative(),
  expiresAtMs: z.number().int().nonnegative()
});

export type TxLock = z.infer<typeof TxLockSchema>;

export const TxGrantResponseSchema = z.discriminatedUnion("granted", [
  z.object({
    granted: z.literal(true),
    lock: TxLockSchema
  }),
  z.object({
    granted: z.literal(false),
    frequency: z.string().min(1),
    currentOwnerRobloxUserId: z.number().int().positive(),
    expiresAtMs: z.number().int().nonnegative()
  })
]);

export type TxGrantResponse = z.infer<typeof TxGrantResponseSchema>;

export const PluginSnapshotSchema = z.object({
  nowMs: z.number().int().nonnegative(),
  localRobloxUserId: z.number().int().positive(),
  
  players: z.array(PlayerRadioStateSchema),
  txLocks: z.array(TxLockSchema)
});

export type PluginSnapshot = z.infer<typeof PluginSnapshotSchema>;