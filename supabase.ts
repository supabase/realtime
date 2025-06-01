mport { createClient } from '@supabase/supabase-js';

const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL as string;
const supabaseAnonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY as string;

export const supabase = createClient(supabaseUrl, supabaseAnonKey, {
  realtime: {
    params: {
      eventsPerSecond: 10,
    },
  },
});

// Function to apply RLS policies to the database
export async function applyRLSPolicies() {
  try {
    // This function should be called from a secure admin context
    const { error } = await supabase.rpc('apply_rls_policies');
    if (error) {
      console.error('Error applying RLS policies:', error);
      return false;
    }
    return true;
  } catch (error) {
    console.error('Exception applying RLS policies:', error);
    return false;
  }
}

// Real-time subscription helpers
export function subscribeToTable(
  tableName: string,
  callback: (payload: any) => void,
  filter?: string
) {
  const channel = supabase
    .channel(`${tableName}_changes`)
    .on(
      'postgres_changes',
      {
        event: '*',
        schema: 'public',
        table: tableName,
        filter: filter,
      },
      callback
    )
    .subscribe();

  return channel;
}

export function unsubscribeFromChannel(channel: any) {
  if (channel) {
    supabase.removeChannel(channel);
  }
}

// Enhanced real-time subscription with error handling and reconnection
export function subscribeToTableWithRetry(
  tableName: string,
  callback: (payload: any) => void,
  options?: {
    filter?: string;
    onError?: (error: any) => void;
    onConnected?: () => void;
    onDisconnected?: () => void;
  }
) {
  const channelName = `${tableName}_changes_${Date.now()}`;
  
  const channel = supabase
    .channel(channelName)
    .on(
      'postgres_changes',
      {
        event: '*',
        schema: 'public',
        table: tableName,
        filter: options?.filter,
      },
      (payload) => {
        console.log(`Real-time update for ${tableName}:`, payload);
        callback(payload);
      }
    )
    .subscribe((status) => {
      console.log(`Subscription status for ${tableName}:`, status);
      
      if (status === 'SUBSCRIBED') {
        options?.onConnected?.();
      } else if (status === 'CLOSED') {
        options?.onDisconnected?.();
      } else if (status === 'CHANNEL_ERROR') {
        options?.onError?.(new Error(`Channel error for ${tableName}`));
      }
    });

  return channel;
}

// Batch subscription manager
export class RealtimeManager {
  private channels: Map<string, any> = new Map();
  private reconnectAttempts: Map<string, number> = new Map();
  private maxReconnectAttempts = 3;

  subscribe(
    tableName: string,
    callback: (payload: any) => void,
    options?: {
      filter?: string;
      onError?: (error: any) => void;
      onConnected?: () => void;
      onDisconnected?: () => void;
    }
  ) {
    // Unsubscribe existing channel if it exists
    this.unsubscribe(tableName);

    const channel = subscribeToTableWithRetry(
      tableName,
      callback,
      {
        ...options,
        onError: (error) => {
          console.error(`Real-time error for ${tableName}:`, error);
          this.handleReconnection(tableName, callback, options);
          options?.onError?.(error);
        },
        onDisconnected: () => {
          console.warn(`Real-time disconnected for ${tableName}`);
          this.handleReconnection(tableName, callback, options);
          options?.onDisconnected?.();
        }
      }
    );

    this.channels.set(tableName, channel);
    this.reconnectAttempts.set(tableName, 0);

    return channel;
  }

  unsubscribe(tableName: string) {
    const channel = this.channels.get(tableName);
    if (channel) {
      unsubscribeFromChannel(channel);
      this.channels.delete(tableName);
      this.reconnectAttempts.delete(tableName);
    }
  }

  unsubscribeAll() {
    for (const [tableName] of this.channels) {
      this.unsubscribe(tableName);
    }
  }

  private handleReconnection(
    tableName: string,
    callback: (payload: any) => void,
    options?: any
  ) {
    const attempts = this.reconnectAttempts.get(tableName) || 0;
    
    if (attempts < this.maxReconnectAttempts) {
      const delay = Math.pow(2, attempts) * 1000; // Exponential backoff
      
      setTimeout(() => {
        console.log(`Attempting to reconnect ${tableName} (attempt ${attempts + 1})`);
        this.reconnectAttempts.set(tableName, attempts + 1);
        this.subscribe(tableName, callback, options);
      }, delay);
    } else {
      console.error(`Max reconnection attempts reached for ${tableName}`);
    }
  }

  getConnectionStatus(tableName: string): boolean {
    const channel = this.channels.get(tableName);
    return channel?.state === 'joined';
  }

  getAllConnectionStatuses(): Record<string, boolean> {
    const statuses: Record<string, boolean> = {};
    for (const [tableName, channel] of this.channels) {
      statuses[tableName] = channel?.state === 'joined';
    }
    return statuses;
  }
}

// Global realtime manager instance
export const realtimeManager = new RealtimeManager();
