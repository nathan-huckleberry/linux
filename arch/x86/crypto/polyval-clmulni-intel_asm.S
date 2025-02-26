/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Copyright 2021 Google LLC
 *
 * Use of this source code is governed by an MIT-style
 * license that can be found in the LICENSE file or at
 * https://opensource.org/licenses/MIT.
 */
/*
 * This is an efficient implementation of POLYVAL using intel PCLMULQDQ-NI
 * instructions. It works on 8 blocks at a time, computing the 256 degree
 * polynomial p(x) = h^8m_0 + ... + h^1m_7. It then computes the modular
 * reduction of p(x) and XORs p(x) with the current digest.
 */

#include <linux/linkage.h>
#include <asm/frame.h>

#define NUM_PRECOMPUTE_POWERS 8

.align 16

#define GSTAR %xmm7
#define PL %xmm8
#define PH %xmm9
#define T %xmm10
#define Z %xmm11
#define C %xmm12
#define D %xmm13
#define EF %xmm14
#define SUM %xmm15

#define BLOCKS_LEFT %rdx
#define OP1 %rdi
#define OP2 %r10
#define IDX %r11
#define TMP %rax

Lgstar:
	.quad 0xc200000000000000, 0xc200000000000000

.text

/*
 * Accepts operand lists of length b in rdi and rsi. Computes the product of
 * each rdi,rsi pair then XORs the products into A, B, C, D.
 *
 * If first == 1 then XOR the value of SUM into the first block processed.
 * This avoids an extra multication of SUM and h^N.
 *
 * XORs product into C, D, EF
 * Preserves SUM
 * All other xmm registers clobbered
 */
.macro schoolbook1 b
	.set by, \b
	.set i, 0
	.rept (by)
		schoolbook1_iteration i 0
		.set i, (i +1)
	.endr
.endm

.macro schoolbook1_iteration i first
	.set first, \first
	.set i, \i
	movups (16*i)(OP1), %xmm0
	.if(i == 0 && first == 1)
		pxor SUM, %xmm0
	.endif
	vpclmulqdq $0x01, (16*i)(OP2), %xmm0, %xmm1
	vpxor %xmm1, EF, EF
	vpclmulqdq $0x00, (16*i)(OP2), %xmm0, %xmm2
	vpxor %xmm2, C, C
	vpclmulqdq $0x11, (16*i)(OP2), %xmm0, %xmm3
	vpxor %xmm3, D, D
	vpclmulqdq $0x10, (16*i)(OP2), %xmm0, %xmm4
	vpxor %xmm4, EF, EF
.endm

/*
 * Computes first schoolbook step of values loaded into xmm0 and xmm1. Used to
 * multiply intermediate register values rather than memory stored values.
 *
 * XORs product into C, D, EF
 * Preserves SUM
 * All other xmm registers clobbered
 */
.macro schoolbook1_noload
	vpclmulqdq $0x01, %xmm0, %xmm1, %xmm2
	vpxor %xmm2, EF, EF
	vpclmulqdq $0x00, %xmm0, %xmm1, %xmm3
	vpxor %xmm3, C, C
	vpclmulqdq $0x11, %xmm0, %xmm1, %xmm4
	vpxor %xmm4, D, D
	vpclmulqdq $0x10, %xmm0, %xmm1, %xmm5
	vpxor %xmm5, EF, EF
.endm

/*
 * Computes the 256-bit polynomial represented by C, D, EF. Stores
 * the result in PL, PH.
 *
 * All other xmm registers are preserved.
 */
.macro schoolbook2
	vpslldq $8, EF, PL
	vpsrldq $8, EF, PH
	pxor C, PL
	pxor D, PH
.endm

/*
 * Computes the 128-bit reduction of PL, PH. Stores the result in PH.
 *
 * PL, PH, Z, T.
 * All other xmm registers are preserved.
 */
.macro montgomery_reduction
	movdqa PL, T
	pclmulqdq $0x00, GSTAR, T # T = [X0 * g*(x)]
	pshufd $0b01001110, T, Z # Z = [T0 : T1]
	pxor Z, PL # PL = [X1 ^ T0 : X0 ^ T1]
	pxor PL, PH # PH = [X1 ^ T0 ^ X3 : X0 ^ T1 ^ X2]
	pclmulqdq $0x11, GSTAR, PL # PL = [X1 ^ T0 * g*(x)]
	pxor PL, PH
.endm

/*
 * Compute schoolbook multiplication for 8 blocks
 * (M_0h + REDUCE(PL, PH))h^8 + ... + M_{7}h^1 (no constant term)
 *
 * Sets PL, PH
 * Clobbers C, D, E
 *
 * If reduce is set, computes the montgomery reduction of the
 * previous full_stride call.
 */
.macro full_stride reduce
	.set reduce, \reduce
	mov %rsi, OP2
	pxor C, C
	pxor D, D
	pxor EF, EF

	schoolbook1_iteration 7 0
	.if(reduce)
		movdqa PL, T
	.endif

	schoolbook1_iteration 6 0
	.if(reduce)
		pclmulqdq $0x00, GSTAR, T # T = [X0 * g*(x)]
	.endif

	schoolbook1_iteration 5 0
	.if(reduce)
		pshufd $0b01001110, T, Z # Z = [T0 : T1]
	.endif

	schoolbook1_iteration 4 0
	.if(reduce)
		pxor Z, PL # PL = [X1 ^ T0 : X0 ^ T1]
	.endif

	schoolbook1_iteration 3 0
	.if(reduce)
		pxor PL, PH # PH = [X1 ^ T0 ^ X3 : X0 ^ T1 ^ X2]
	.endif

	schoolbook1_iteration 2 0
	.if(reduce)
		pclmulqdq $0x11, GSTAR, PL # PL = [X1 ^ T0 * g*(x)]
	.endif

	schoolbook1_iteration 1 0
	.if(reduce)
		pxor PL, PH
		movdqa PH, SUM
	.endif

	schoolbook1_iteration 0 1

	addq $(8*16), OP1
	addq $(8*16), OP2
	schoolbook2
.endm

/*
 * Compute poly on window size of %rdx blocks
 * 0 < %rdx < NUM_PRECOMPUTE_POWERS
 */
.macro partial_stride
	pxor C, C
	pxor D, D
	pxor EF, EF
	mov BLOCKS_LEFT, TMP
	shlq $4, TMP
	mov %rsi, OP2
	addq $(16*NUM_PRECOMPUTE_POWERS), OP2
	subq TMP, OP2
	# Multiply sum by h^N
	movups (OP2), %xmm0
	movdqa SUM, %xmm1
	schoolbook1_noload
	schoolbook2
	montgomery_reduction
	movdqa PH, SUM
	pxor C, C
	pxor D, D
	pxor EF, EF
	xor IDX, IDX
.LloopPartial:
	cmpq BLOCKS_LEFT, IDX # IDX < rdx
	jae .LloopExitPartial

	movq BLOCKS_LEFT, TMP
	subq IDX, TMP # TMP = rdx - IDX

	cmp $4, TMP # TMP < 4 ?
	jl .Llt4Partial
	schoolbook1 4
	addq $4, IDX
	addq $(4*16), OP1
	addq $(4*16), OP2
	jmp .LoutPartial
.Llt4Partial:
	cmp $3, TMP # TMP < 3 ?
	jl .Llt3Partial
	schoolbook1 3
	addq $3, IDX
	addq $(3*16), OP1
	addq $(3*16), OP2
	jmp .LoutPartial
.Llt3Partial:
	cmp $2, TMP # TMP < 2 ?
	jl .Llt2Partial
	schoolbook1 2
	addq $2, IDX
	addq $(2*16), OP1
	addq $(2*16), OP2
	jmp .LoutPartial
.Llt2Partial:
	schoolbook1 1 # TMP < 1 ?
	addq $1, IDX
	addq $(1*16), OP1
	addq $(1*16), OP2
.LoutPartial:
	jmp .LloopPartial
.LloopExitPartial:
	schoolbook2
	montgomery_reduction
	pxor PH, SUM
.endm

/*
 * Perform montgomery multiplication in GF(2^128) and store result in op1.
 *
 * Computes op1*op2*x^{-128} mod x^128 + x^127 + x^126 + x^121 + 1
 * If op1, op2 are in montgomery form,  this computes the montgomery
 * form of op1*op2.
 *
 * void clmul_polyval_mul(ble128 *op1, const ble128 *op2);
 */
SYM_FUNC_START(clmul_polyval_mul)
	FRAME_BEGIN
	vmovdqa Lgstar(%rip), GSTAR
	pxor C, C
	pxor D, D
	pxor EF, EF
	mov %rsi, OP2
	schoolbook1 1
	schoolbook2
	montgomery_reduction
	movups PH, (%rdi)
	FRAME_END
	ret
SYM_FUNC_END(clmul_polyval_mul)

/*
 * Perform polynomial evaluation as specified by POLYVAL. Multiplies the value
 * stored at accumulator by h^k and XORs the evaluated polynomial into it.
 *
 * Computes h^k*accumulator + h^kM_0 + ... + h^1M_{k-1} (No constant term)
 *
 * rdi (OP1) - pointer to message blocks
 * rsi - pointer to precomputed key struct
 * rdx - number of blocks to hash
 * rcx - location to XOR with evaluated polynomial
 *
 * void clmul_polyval_update(const u8 *in, const struct polyhash_key* keys,
 *			     size_t nblocks, ble128* accumulator);
 */
SYM_FUNC_START(clmul_polyval_update)
	FRAME_BEGIN
	vmovdqa Lgstar(%rip), GSTAR
	movups (%rcx), SUM
	cmpq $NUM_PRECOMPUTE_POWERS, BLOCKS_LEFT
	jb .LstrideLoopExit
	full_stride 0
	subq $NUM_PRECOMPUTE_POWERS, BLOCKS_LEFT
.LstrideLoop:
	cmpq $NUM_PRECOMPUTE_POWERS, BLOCKS_LEFT
	jb .LstrideLoopExitReduce
	full_stride 1
	subq $NUM_PRECOMPUTE_POWERS, BLOCKS_LEFT
	jmp .LstrideLoop
.LstrideLoopExitReduce:
	montgomery_reduction
	movdqa PH, SUM
.LstrideLoopExit:
	test BLOCKS_LEFT, BLOCKS_LEFT
	je .LskipPartial
	partial_stride
.LskipPartial:
	movups SUM, (%rcx)
	FRAME_END
	ret
SYM_FUNC_END(clmul_polyval_update)
