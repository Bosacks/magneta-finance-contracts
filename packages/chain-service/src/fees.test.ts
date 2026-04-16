import { describe, it, expect } from 'vitest';
import { quoteFee, opKind } from './fees';
import { OpType } from './types';

describe('fees.opKind', () => {
    it('classifies LP + swap + mint as value ops', () => {
        for (const op of [OpType.CREATE_LP, OpType.REMOVE_LP, OpType.CREATE_LP_AND_BUY,
                          OpType.SWAP_LOCAL, OpType.SWAP_OUT, OpType.MINT, OpType.CLAIM_TAX_FEES]) {
            expect(opKind(op)).toBe('value');
        }
    });

    it('classifies metadata + freeze + revoke as command ops', () => {
        for (const op of [OpType.UPDATE_METADATA, OpType.FREEZE_ACCOUNT, OpType.UNFREEZE_ACCOUNT,
                          OpType.AUTO_FREEZE, OpType.REVOKE_PERMISSION, OpType.BURN_LP]) {
            expect(opKind(op)).toBe('command');
        }
    });
});

describe('fees.quoteFee', () => {
    it('applies 0.15% markup on value ops', () => {
        const q = quoteFee({
            op: OpType.CREATE_LP,
            valueUsdc6d: 10_000_000_000n, // $10,000
            routingFeeUsdc6d: 0n,
            gasCostNative: 0n,
        });
        expect(q.magnetaFeeUsdc).toBe(15_000_000n); // $15.00
        expect(q.userTotalUsdc).toBe(15_000_000n);
    });

    it('applies flat $1 fee on command ops regardless of value', () => {
        const q = quoteFee({
            op: OpType.FREEZE_ACCOUNT,
            valueUsdc6d: 999_999_999_999n, // ignored for command ops
            routingFeeUsdc6d: 0n,
            gasCostNative: 0n,
        });
        expect(q.magnetaFeeUsdc).toBe(1_000_000n); // $1.00 flat
    });

    it('sums Magneta fee + routing into userTotalUsdc, leaves gas separate', () => {
        const q = quoteFee({
            op: OpType.SWAP_LOCAL,
            valueUsdc6d: 1_000_000_000n, // $1,000
            routingFeeUsdc6d: 2_500_000n, // $2.50 aggregator fee
            gasCostNative: 50_000_000_000_000_000n, // 0.05 ETH
        });
        expect(q.magnetaFeeUsdc).toBe(1_500_000n); // $1.50 (0.15%)
        expect(q.userTotalUsdc).toBe(4_000_000n); // $4.00 total USDC
        expect(q.gasCostNative).toBe(50_000_000_000_000_000n);
    });
});
