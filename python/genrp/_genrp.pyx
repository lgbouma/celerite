# distutils: language = c++
from __future__ import division

__all__ = ["get_library_version", "GP", "GradGP", "Solver"]

cimport cython

import time
import numpy as np
cimport numpy as np
from libc.math cimport fabs, exp, cos

DTYPE = np.float64
ctypedef np.float64_t DTYPE_t
CDTYPE = np.complex128
ctypedef np.complex128_t CDTYPE_t

cdef extern from "genrp/version.h":
    cdef int GENRP_VERSION_MAJOR
    cdef int GENRP_VERSION_MINOR
    cdef int GENRP_VERSION_REVISION

def get_library_version():
    return "{0}.{1}.{2}".format(
        GENRP_VERSION_MAJOR,
        GENRP_VERSION_MINOR,
        GENRP_VERSION_REVISION
    )

cdef extern from "Eigen/Core" namespace "Eigen":
    cdef cppclass VectorXd:
        VectorXd ()
        double* data()
        double operator () (int i)
        int rows ()

    cdef cppclass Map[T]:
        Map(double*, int)

cdef extern from "unsupported/Eigen/AutoDiff" namespace "Eigen":
    cdef cppclass AutoDiffScalar[T]:
        AutoDiffScalar()
        AutoDiffScalar(double value)
        AutoDiffScalar(double value, Map[VectorXd] grad)
        double value ()
        VectorXd derivatives ()

cdef extern from "genrp/genrp.h" namespace "genrp":

    cdef cppclass Kernel[T]:
        Kernel()
        void add_term (const T log_amp, const T log_q)
        void add_term (const T log_amp, const T log_q, const T log_freq)
        T value (double dt) const
        T psd (double f) const
        size_t p () const
        size_t p_real () const
        size_t p_complex () const

    cdef cppclass BandSolver[T]:
        BandSolver ()
        void compute (
            size_t p_real, const T* const alpha_real, const T* const beta_real,
            size_t p_complex, const T* const alpha_complex,
            const T* const beta_complex_real, const T* const beta_complex_imag,
            size_t N, const double* t, const T* d)
        void solve (const double* b, T* x) const
        void solve (size_t nrhs, const double* b, T* x) const
        T solve_dot (const double* b) const
        T log_determinant () const

    cdef cppclass GaussianProcess[SolverType, T]:
        GaussianProcess (Kernel[T] kernel)
        size_t size () const
        const Kernel[T] kernel () const
        SolverType solver () const
        void compute (size_t N, const double* x, const double* yerr)
        T log_likelihood (const double* y) const
        T kernel_value (double dt) const
        T kernel_psd (double w) const
        void get_params (T* pars) const
        void set_params (const T* const pars)
        void get_alpha_real (T* alpha) const
        void get_beta_real (T* alpha) const
        void get_alpha_complex (T* alpha) const
        void get_beta_complex_real (T* beta) const
        void get_beta_complex_imag (T* beta) const


cdef class GP:

    cdef GaussianProcess[BandSolver[double], double]* gp
    cdef Kernel[double] kernel

    cdef GaussianProcess[BandSolver[AutoDiffScalar[VectorXd] ], AutoDiffScalar[VectorXd] ]* grad_gp
    cdef Kernel[AutoDiffScalar[VectorXd] ] grad_kernel

    cdef int _data_size
    cdef int _grad_data_size

    cdef object _terms

    def __cinit__(self):
        self.gp = new GaussianProcess[BandSolver[double], double](self.kernel)
        self.grad_gp = new GaussianProcess[BandSolver[AutoDiffScalar[VectorXd] ], AutoDiffScalar[VectorXd] ](self.grad_kernel)
        self._data_size = -1
        self._grad_data_size = -1
        self._terms = []

    def __dealloc__(self):
        del self.gp
        del self.grad_gp

    def __len__(self):
        return self.gp.size()

    property computed:
        def __get__(self):
            return self._data_size >= 0

    property grad_computed:
        def __get__(self):
            return self._grad_data_size >= 0

    property alpha_real:
        def __get__(self):
            cdef np.ndarray[DTYPE_t] a = np.empty(self.gp.kernel().p_real(), dtype=DTYPE)
            self.gp.get_alpha_real(<double*>a.data)
            return a

    property beta_real:
        def __get__(self):
            cdef np.ndarray[DTYPE_t] a = np.empty(self.gp.kernel().p_real(), dtype=DTYPE)
            self.gp.get_beta_real(<double*>a.data)
            return a

    property alpha_complex:
        def __get__(self):
            cdef np.ndarray[DTYPE_t] a = np.empty(self.gp.kernel().p_complex(), dtype=DTYPE)
            self.gp.get_alpha_complex(<double*>a.data)
            return a

    property beta_complex_real:
        def __get__(self):
            cdef np.ndarray[DTYPE_t] a = np.empty(self.gp.kernel().p_complex(), dtype=DTYPE)
            self.gp.get_beta_complex_real(<double*>a.data)
            return a

    property beta_complex_imag:
        def __get__(self):
            cdef np.ndarray[DTYPE_t] a = np.empty(self.gp.kernel().p_complex(), dtype=DTYPE)
            self.gp.get_beta_complex_imag(<double*>a.data)
            return a

    property params:
        def __get__(self):
            cdef np.ndarray[DTYPE_t] p = np.empty(self.gp.size(), dtype=DTYPE)
            self.gp.get_params(<double*>p.data)
            return p

        def __set__(self, params):
            if len(params) != self.gp.size():
                raise ValueError("dimension mismatch")

            cdef np.ndarray[DTYPE_t, ndim=1] p = \
                np.atleast_1d(params).astype(DTYPE)

            # Set the parameters in the scalar solver
            self.gp.set_params(<double*>p.data)

            self._data_size = -1
            self._grad_data_size = -1

    def __getitem__(self, i):
        return self.params[i]

    def __setitem__(self, i, value):
        params = self.params
        params[i] = value
        self.params = params

    def add_term(self, log_a, log_q, log_f=None):
        cdef double la, lq, lf
        cdef AutoDiffScalar[VectorXd] ad_la, ad_lq, ad_lf
        cdef np.ndarray[DTYPE_t, ndim=1] grad_la, grad_lq, grad_lf

        try:
            if len(log_a) != 2:
                raise ValueError("invalid term amplitude parameter")
        except TypeError:
            la = log_a
            ad_la = AutoDiffScalar[VectorXd](la)
        else:
            la = log_a[0]
            grad_la = np.atleast_1d(log_a[1])
            ad_la = AutoDiffScalar[VectorXd](la, Map[VectorXd](<double*>grad_la.data, grad_la.shape[0]))

        try:
            if len(log_q) != 2:
                raise ValueError("invalid term q-factor parameter")
        except TypeError:
            lq = log_q
            ad_lq = AutoDiffScalar[VectorXd](lq)
        else:
            lq = log_q[0]
            grad_lq = np.atleast_1d(log_q[1])
            ad_lq = AutoDiffScalar[VectorXd](lq, Map[VectorXd](<double*>grad_lq.data, grad_lq.shape[0]))

        if log_f is None:
            self.kernel.add_term(la, lq)
            self.grad_kernel.add_term(ad_la, ad_lq)

        else:
            try:
                if len(log_f) != 2:
                    raise ValueError("invalid term frequency parameter")
            except TypeError:
                lf = log_f
                ad_lf = AutoDiffScalar[VectorXd](lf)
            else:
                lf = log_f[0]
                grad_lf = np.atleast_1d(log_f[1])
                ad_lf = AutoDiffScalar[VectorXd](lf, Map[VectorXd](<double*>grad_lf.data, grad_lf.shape[0]))

            self.kernel.add_term(la, lq, lf)
            self.grad_kernel.add_term(ad_la, ad_lq, ad_lf)

        # Save the term
        self._terms.append((log_a, log_q, log_f))

        # Update the solvers
        del self.gp
        self.gp = new GaussianProcess[BandSolver[double], double](self.kernel)
        del self.grad_gp
        self.grad_gp = new GaussianProcess[BandSolver[AutoDiffScalar[VectorXd] ], AutoDiffScalar[VectorXd] ](self.grad_kernel)

        self._data_size = -1
        self._grad_data_size = -1

    def get_matrix(self, np.ndarray[DTYPE_t, ndim=1] x1, x2=None):
        if x2 is None:
            x2 = x1
        cdef np.ndarray[DTYPE_t, ndim=2] K = x1[:, None] - x2[None, :]
        cdef int i, j
        for i in range(x1.shape[0]):
            for j in range(x2.shape[0]):
                K[i, j] = self.gp.kernel_value(K[i, j])
        return K

    def get_psd(self, np.ndarray[DTYPE_t, ndim=1] w):
        cdef np.ndarray[DTYPE_t, ndim=1] psd = np.empty_like(w, dtype=DTYPE)
        cdef int i
        for i in range(w.shape[0]):
            psd[i] = self.gp.kernel_psd(w[i])
        return psd

    def compute(self, np.ndarray[DTYPE_t, ndim=1] x, np.ndarray[DTYPE_t, ndim=1] yerr):
        if x.shape[0] != yerr.shape[0]:
            raise ValueError("dimension mismatch")
        cdef int i
        for i in range(x.shape[0] - 1):
            if x[i+1] <= x[i]:
                raise ValueError("the time series must be ordered")
        self._data_size = x.shape[0]
        self.gp.compute(self._data_size, <double*>x.data, <double*>yerr.data)

    def compute_grad(self, np.ndarray[DTYPE_t, ndim=1] x, np.ndarray[DTYPE_t, ndim=1] yerr):
        if x.shape[0] != yerr.shape[0]:
            raise ValueError("dimension mismatch")
        cdef int i
        for i in range(x.shape[0] - 1):
            if x[i+1] <= x[i]:
                raise ValueError("the time series must be ordered")
        self._grad_data_size = x.shape[0]
        self.grad_gp.compute(self._grad_data_size, <double*>x.data, <double*>yerr.data)

    def log_likelihood(self, np.ndarray[DTYPE_t, ndim=1] y):
        if not self.computed:
            raise RuntimeError("you must call 'compute' first")
        if y.shape[0] != self._data_size:
            raise ValueError("dimension mismatch")
        return self.gp.log_likelihood(<double*>y.data)

    def grad_log_likelihood(self, np.ndarray[DTYPE_t, ndim=1] y):
        if not self.grad_computed:
            raise RuntimeError("you must call 'compute_grad' first")
        if y.shape[0] != self._data_size:
            raise ValueError("dimension mismatch")

        cdef AutoDiffScalar[VectorXd] ll = self.grad_gp.log_likelihood(<double*>y.data)
        cdef VectorXd grad = ll.derivatives()
        cdef np.ndarray[DTYPE_t, ndim=1] grad_ll = np.empty(grad.rows(), dtype=DTYPE)
        cdef int i
        for i in range(grad.rows()):
            grad_ll[i] = grad(i)
        return ll.value(), grad_ll

    def sample(self, np.ndarray[DTYPE_t, ndim=1] x, double tiny=1e-12):
        cdef np.ndarray[DTYPE_t, ndim=2] K = self.get_matrix(x)
        K[np.diag_indices_from(K)] += tiny
        return np.random.multivariate_normal(np.zeros_like(x), K)


cdef class Solver:

    cdef BandSolver[double]* solver
    cdef unsigned int N
    cdef np.ndarray t
    cdef np.ndarray diagonal
    cdef unsigned int p_real
    cdef np.ndarray alpha_real
    cdef np.ndarray beta_real
    cdef unsigned int p_complex
    cdef np.ndarray alpha_complex
    cdef np.ndarray beta_complex_real
    cdef np.ndarray beta_complex_imag

    def __cinit__(self,
                  np.ndarray[DTYPE_t, ndim=1] alpha_real,
                  np.ndarray[DTYPE_t, ndim=1] beta_real,
                  np.ndarray[DTYPE_t, ndim=1] alpha_complex,
                  np.ndarray[DTYPE_t, ndim=1] beta_complex_real,
                  np.ndarray[DTYPE_t, ndim=1] beta_complex_imag,
                  np.ndarray[DTYPE_t, ndim=1] t,
                  d=1e-10):
        if not np.all(np.diff(t) > 0.0):
            raise ValueError("times must be sorted")

        # Check the shapes:
        if alpha_real.shape[0] != beta_real.shape[0]:
            raise ValueError("dimension mismatch")
        if alpha_complex.shape[0] != beta_complex_real.shape[0]:
            raise ValueError("dimension mismatch")
        if alpha_complex.shape[0] != beta_complex_imag.shape[0]:
            raise ValueError("dimension mismatch")

        # Save the dimensions
        self.N = t.shape[0]
        self.t = t
        self.p_real = alpha_real.shape[0]
        self.alpha_real = alpha_real
        self.beta_real = beta_real
        self.p_complex = alpha_complex.shape[0]
        self.alpha_complex = alpha_complex
        self.beta_complex_real = beta_complex_real
        self.beta_complex_imag = beta_complex_imag

        try:
            d = float(d)
        except TypeError:
            d = np.atleast_1d(d)
            if d.shape[0] != self.N:
                raise ValueError("diagonal dimension mismatch")
        else:
            d = d + np.zeros_like(self.t)
        self.diagonal = d

        self.solver = new BandSolver[double]()
        self.solver.compute(
            self.p_real,
            <double*>(self.alpha_real.data),
            <double*>(self.beta_real.data),
            self.p_complex,
            <double*>(self.alpha_complex.data),
            <double*>(self.beta_complex_real.data),
            <double*>(self.beta_complex_imag.data),
            self.N,
            <double*>(self.t.data),
            <double*>(self.diagonal.data)
        )

    def __dealloc__(self):
        del self.solver

    property log_determinant:
        def __get__(self):
            return self.solver.log_determinant()

    def apply_inverse(self, np.ndarray[DTYPE_t, ndim=1] y, in_place=False):
        if y.shape[0] != self.N:
            raise ValueError("dimension mismatch")

        if in_place:
            self.solver.solve(<double*>y.data, <double*>y.data)
            return y

        cdef np.ndarray[DTYPE_t, ndim=1] alpha = np.empty_like(y, dtype=DTYPE)
        self.solver.solve(<double*>y.data, <double*>alpha.data)
        return alpha

    def get_matrix(self):
        cdef double asum = self.alpha_real.sum() + self.alpha_complex.sum()
        cdef double delta
        cdef double value
        cdef size_t i, j, p
        cdef np.ndarray[DTYPE_t, ndim=2] A = np.empty((self.N, self.N),
                                                      dtype=DTYPE)
        for i in range(self.N):
            A[i, i] = self.diagonal[i] + asum
            for j in range(i + 1, self.N):
                delta = fabs(self.t[i] - self.t[j])
                value = 0.0
                for p in range(self.p_real):
                    value += self.alpha_real[p]*exp(-self.beta_real[p]*delta)
                for p in range(self.p_complex):
                    value += self.alpha_complex[p]*(
                        exp(-self.beta_complex_real[p]*delta) *
                        cos(self.beta_complex_imag[p]*delta)
                    )
                A[i, j] = value
                A[j, i] = value
        return A
