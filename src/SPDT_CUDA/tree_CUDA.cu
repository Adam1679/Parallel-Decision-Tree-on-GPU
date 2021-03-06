
#include "array_CUDA.cu_inl"
#include "../SPDT_general/timing.h"
#include "panel.h"
#include <assert.h>
#include <queue>
#include <stdio.h>
#include <algorithm>
#include <math.h>
#include <cuda.h>
#include <cuda_runtime.h>
#include <driver_functions.h>
#include "array_CUDA.h"
#include "tree_CUDA.h"
#include "parser_CUDA.h"

// https://stackoverflow.com/questions/14038589/what-is-the-canonical-way-to-check-for-errors-using-the-cuda-runtime-api
#define gpuErrchk(ans) { gpuAssert((ans), __FILE__, __LINE__); }

double COMPRESS_TIME = 0.f;
double SPLIT_TIME = 0.f;
double COMMUNICATION_TIME = 0.f;
double COMPRESS_COMMUNICATION_TIME = 0.f;
double SPLIT_COMMUNICATION_TIME = 0.f;
long long SIZE = 0 ;

int num_of_features = -1;
int num_of_classes = -1;
int max_bin_size = -1;
int max_num_leaves = -1;

__constant__ GlobalConstants cuConstTreeParams;

void prefix_printf(const char* format, ...){
    va_list args;
    printf("CUDA ");
    va_start(args, format);
    vprintf(format, args);
    va_end(args);
}

inline void gpuAssert(cudaError_t code, const char *file, int line, bool abort=true)
{
   if (code != cudaSuccess) 
   {
      fprintf(stderr,"GPUassert: %s %s %d\n", cudaGetErrorString(code), file, line);
      if (abort) exit(code);
   }
}

/*
 * Similar to update
 */
__global__ void
histogram_update_kernel() {

    // compute overall index from position of thread in current block,
    // and given the block we are in
    int data_id = blockIdx.x;
    int feature_id = threadIdx.x;
    int data_size = cuConstTreeParams.num_of_data;
    int num_of_features = cuConstTreeParams.num_of_features;

    if (data_id >= data_size || feature_id >= num_of_features)
       return;

    int* cuda_label_ptr = cuConstTreeParams.cuda_label_ptr;
    float* cuda_value_ptr = cuConstTreeParams.cuda_value_ptr;
    int* cuda_histogram_id_ptr = cuConstTreeParams.cuda_histogram_id_ptr;
	int num_of_classes = cuConstTreeParams.num_of_classes;
    int max_bin_size = cuConstTreeParams.max_bin_size;
    float* _histogram_ = cuConstTreeParams.cuda_histogram_ptr;
    CUDA_update_array(
        cuda_histogram_id_ptr[data_id], 
        feature_id, 
        cuda_label_ptr[data_id], 
        cuda_value_ptr[data_id * num_of_features + feature_id],
        num_of_features,
        num_of_classes,
        max_bin_size,
        _histogram_);
}

// block_num: size of unlabeled leaves
// thread_num: num_of_features
__global__ void
histogram_update_kernel_2() {
    int histogram_id = blockIdx.x;
    int feature_id = threadIdx.x;    
    int num_of_features = cuConstTreeParams.num_of_features;    

    if (histogram_id >= cuConstTreeParams.max_num_leaves || feature_id >= num_of_features)
       return;

    int* cuda_label_ptr = cuConstTreeParams.cuda_label_ptr;
    float* cuda_value_ptr = cuConstTreeParams.cuda_value_ptr;
    int* cuda_histogram_id_ptr = cuConstTreeParams.cuda_histogram_id_ptr;
	int num_of_classes = cuConstTreeParams.num_of_classes;
    int max_bin_size = cuConstTreeParams.max_bin_size;
    float* _histogram_ = cuConstTreeParams.cuda_histogram_ptr;

    for (int i = 0; i < cuConstTreeParams.num_of_data; i++) {
        if (cuda_histogram_id_ptr[i] != histogram_id) continue;
        CUDA_update_array(
            cuda_histogram_id_ptr[i], 
            feature_id, 
            cuda_label_ptr[i], 
            cuda_value_ptr[i * num_of_features + feature_id],
            num_of_features,
            num_of_classes,
            max_bin_size,
            _histogram_);
        __syncthreads();
    }
    
}

SplitPoint::SplitPoint()
{
    feature_id = -1;
    feature_value = 0;
    entropy = 0;
}

SplitPoint::SplitPoint(int feature_id, float feature_value)
{
    this->feature_id = feature_id;
    this->feature_value = feature_value;
    this->entropy = 0;    
}
/*
 * Reture True if the data is larger or equal than the split value
 */
bool SplitPoint::decision_rule(int data_index, Dataset *datasetPointer)
{        
    dbg_ensures(entropy >= -EPS);    
    dbg_ensures(gain >= -EPS);    
    dbg_ensures(feature_id >= 0);
    dbg_ensures(feature_id < num_of_features);     
    assert(datasetPointer->value_ptr != NULL);        
    assert(data_index * num_of_features + feature_id >= 0); 

    // printf("data_index %d\n", data_index);
    // printf("num_of_features %d\n", num_of_features);
    // printf("feature_id %d\n", feature_id);
    // printf("datasetPointer->num_of_data %d\n", datasetPointer->num_of_data);

    assert((long long int) data_index * num_of_features + feature_id < 
        (long long int) datasetPointer->num_of_data * num_of_features);    
    bool result = datasetPointer->value_ptr[data_index * num_of_features + feature_id] >= feature_value;        
    return result;
}

// constructor function
TreeNode::TreeNode(int depth, int id, Dataset* datasetPointer)
{
    this->id = id;
    this->depth = depth;
    is_leaf = false;
    label = -1;    
    histogram_id = -1;    
    left_node = NULL;
    right_node = NULL;
    entropy = -1.f;
    num_pos_label=0;
    data_size = 0;
    is_leaf = true;
    this->datasetPointer = datasetPointer;
}


void TreeNode::init()
{
    label = -1;
    histogram_id = -1;    
    left_node = NULL;
    right_node = NULL;
    is_leaf = true;
    return;
}

/*
 * Set label for the node as the majority class.
 */
void TreeNode::set_label()
{
    this->is_leaf = true;
    this->label = (this->num_pos_label >= (int)this->data_size / 2) ? POS_LABEL : NEG_LABEL;
}

/*
 * This function split the data according to the best split feature id and value.
 * The data would be appended to the `left` if the data value is smaller than the split value
 */
void TreeNode::split(SplitPoint &best_split, TreeNode* left, TreeNode* right)
{    
    assert(left != NULL);
    assert(right != NULL);
    this->split_ptr = best_split;
    this->entropy = best_split.entropy;
    int num_pos_label_left=0;
    int num_pos_label_right=0;
    for (int i = 0; i < this->data_ptr.size(); i++) {        
        int data_index = this->data_ptr[i];
        if (best_split.decision_rule(data_index, this->datasetPointer)) {                        
            right->data_ptr.push_back(data_index);
            this->datasetPointer->histogram_id_ptr[data_index] = right->id;
            assert(this->datasetPointer->label_ptr != NULL);
            num_pos_label_right = (this->datasetPointer->label_ptr[data_index] == POS_LABEL) ? num_pos_label_right + 1 : num_pos_label_right;
            right->data_size++;
        } else {            
            left->data_ptr.push_back(data_index);
            this->datasetPointer->histogram_id_ptr[data_index] = left->id;
            assert(this->datasetPointer->label_ptr != NULL);           
            num_pos_label_left = (this->datasetPointer->label_ptr[data_index] == POS_LABEL) ? num_pos_label_left + 1 : num_pos_label_left;
            left->data_size++;
        }
    }
   
    left->num_pos_label = num_pos_label_left;
    right->num_pos_label = num_pos_label_right;

    dbg_assert(left->num_pos_label >= 0);
    dbg_assert(right->num_pos_label >= 0);
    dbg_assert(left->num_pos_label + right->num_pos_label == this->num_pos_label);
    dbg_assert(left->data_size + right->data_size == this->data_size);    
}

void TreeNode::printspaces() {
    int i = 0;
    for (i = 0; i < depth * 2; i++) {
        printf(" ");
    }
}

void TreeNode::print() {
    printspaces();
    printf("TreeNode: \n");
    printspaces();
    printf("depth: %d\n", depth);
    printspaces();
    printf("label %d\n", label);
    printspaces();
    printf("is_leaf %d\n", is_leaf);
    printspaces();
    printf("hasLeft: %d\n", left_node != NULL);
    printspaces();
    printf("hasRight: %d\n", right_node != NULL);    
    if (left_node != NULL) {
        left_node->print();
    }

    if (right_node != NULL) {
        right_node->print();
    }
}

void TreeNode::clear(){
    if (left_node != NULL) left_node->clear();
    if (right_node != NULL) right_node->clear();    
}

DecisionTree::DecisionTree()
{
    this->max_num_leaves = 64;
    this->max_depth = -1;
    this->min_node_size = 1;
    this->depth = 0;
    this->num_leaves = 0;    
    this->cur_depth = 0;
    this->root = NULL;    
    this->min_gain = 1e-3;
    this->num_nodes = 0;

}

DecisionTree::~DecisionTree(){    
    root->clear();
}


void DecisionTree::initCUDA() {
    int data_size = this->datasetPointer->num_of_data;
    // Construct the histogram. and navigate each data to its leaf. 
    Timer t = Timer();
    t.reset();        
    gpuErrchk(cudaMalloc(&cuda_histogram_ptr, sizeof(float) * SIZE));
    // printf("cuda_histogram_ptr: malloc time %f\n", t.elapsed());

    t.reset(); 
    gpuErrchk(cudaMalloc(&cuda_label_ptr, sizeof(int) * data_size));
    // printf("cuda_label_ptr: malloc time %f\n", t.elapsed());

    t.reset(); 
    gpuErrchk(cudaMalloc(&cuda_value_ptr, sizeof(float) * data_size * num_of_features));
    // printf("cuda_value_ptr: malloc time %f\n", t.elapsed());

    t.reset(); 
    gpuErrchk(cudaMalloc(&cuda_histogram_id_ptr, sizeof(int) * data_size));
    // printf("cuda_histogram_id_ptr: malloc time %f\n", t.elapsed());

    t.reset(); 
    gpuErrchk(cudaMemcpy(cuda_histogram_ptr,
        histogram,
        sizeof(float) * SIZE,
        cudaMemcpyHostToDevice));
    // printf("cuda_histogram_ptr: memcpy time %f\n", t.elapsed());

    t.reset(); 
    gpuErrchk(cudaMemcpy(cuda_label_ptr,
        this->datasetPointer->label_ptr,
        sizeof(int) * data_size,
        cudaMemcpyHostToDevice)); 
    // printf("cuda_label_ptr: memcpy time %f\n", t.elapsed());

    t.reset(); 
    gpuErrchk(cudaMemcpy(cuda_value_ptr,
        this->datasetPointer->value_ptr,
        sizeof(float) * data_size * num_of_features,
        cudaMemcpyHostToDevice));
    // printf("cuda_value_ptr: memcpy time %f\n", t.elapsed());  

    t.reset(); 
    gpuErrchk(cudaMemcpy(cuda_histogram_id_ptr,
        this->datasetPointer->histogram_id_ptr,
        sizeof(int) * data_size,
        cudaMemcpyHostToDevice));
    // printf("cuda_histogram_id_ptr: mempcy time %f\n", t.elapsed()); 

    GlobalConstants params;
    params.cuda_histogram_id_ptr = cuda_histogram_id_ptr;
    params.cuda_histogram_ptr = cuda_histogram_ptr;
    params.cuda_label_ptr = cuda_label_ptr;
    params.cuda_value_ptr = cuda_value_ptr;
    params.num_of_data = data_size;
    params.num_of_classes = num_of_classes;
    params.max_bin_size = max_bin_size;
    params.num_of_features = num_of_features;
    params.max_num_leaves = max_num_leaves;
    gpuErrchk(cudaMemcpyToSymbol(cuConstTreeParams, &params, sizeof(GlobalConstants)));

}

void DecisionTree::terminateCUDA() {
    cudaFree(cuda_histogram_ptr);
    cudaFree(cuda_label_ptr);
    cudaFree(cuda_value_ptr);
    cudaFree(cuda_histogram_id_ptr);
}

/* 
 * Return true if the node should be a leaf.
 * This is determined by the min-node-size, max-depth, max_num_leaves
*/
bool DecisionTree::is_terminated(TreeNode *node)
{
    if (min_node_size != -1 && node->data_size <= min_node_size)
    {
        printf("Node [%d] terminated: min_node_size=%d >= %d\n", node->id, min_node_size, node->data_size);
        return true;
    }

    if (max_depth != -1 && node->depth >= this->max_depth)
    {
        printf("Node [%d] terminated: max_depth\n", node->id);
        return true;
    }

    if (max_num_leaves != -1 && this->num_leaves >= this->max_num_leaves)
    {
        printf("Node [%d] terminated: max_num_leaves\n", node->id);
        return true;
    }

    if (!node->num_pos_label || node->num_pos_label == (int) node->data_size){
        dbg_assert(node->entropy < EPS);
        printf("Node [%d] terminated: all samples belong to same class\n",node->id);
        return true; 
    }
    dbg_printf("[%d] num_data=%d, num_pos=%d\n", node->id, node->data_size, node->num_pos_label);
    return false;
}

void DecisionTree::initialize(Dataset &train_data, const int batch_size){
    COMPRESS_TIME = 0.f;
    SPLIT_TIME = 0.f;
    COMMUNICATION_TIME = 0.f;
    COMPRESS_COMMUNICATION_TIME = 0.f;
    SPLIT_COMMUNICATION_TIME = 0.f;
    this->datasetPointer = &train_data;    
    root = new TreeNode(0, this->num_nodes++, datasetPointer);  
    root->data_size = train_data.num_of_data;
    for (int i = 0; i < root->data_size; i++) {
        root->data_ptr.push_back(i);
    }

    if (histogram != NULL) {        
        delete[] histogram;
    }    
    SIZE = (long long) max_num_leaves * num_of_features * num_of_classes * ((max_bin_size + 1) * 2 + 1);    
    dbg_printf("Init Root Node [%.4f] MB\n", SIZE * sizeof(float) / 1024.f / 1024.f);
    
    histogram = new float[SIZE];
    memset(histogram, 0, SIZE * sizeof(float));  
}

void DecisionTree::train(Dataset &train_data, const int batch_size)
{
    int hasNext = TRUE;

    initialize(train_data, batch_size);
	while (TRUE) {
		hasNext = train_data.streaming_read_data(batch_size);	
        dbg_printf("Train size (%d, %d, %d)\n", train_data.num_of_data, 
                num_of_features, num_of_classes);
                
        Timer t = Timer();
        t.reset();
        initCUDA();
        COMMUNICATION_TIME += t.elapsed();
        train_on_batch(train_data);        
		if (!hasNext) break;
	}		
    
    train_data.close_read_data();
    terminateCUDA(); 
    return;
}

float DecisionTree::test(Dataset &test_data) {    

    int i = 0;
    int correct_num = 0;
    test_data.streaming_read_data(test_data.num_of_data);   
    this->datasetPointer = &test_data;     

    for (i = 0; i < test_data.num_of_data; i++) {        
        assert(navigate(i, &test_data)->label != -1);        
        if (navigate(i, &test_data)->label == test_data.label_ptr[i]) {
            correct_num++;
        }
    }    
    return (float)correct_num / (float)test_data.num_of_data;
}

__global__ void
calculate_feature_value_kernel(int histogram_id, int* cuda_feature_value_num, int* cuda_feature_id, float* cuda_feature_value) {    
    int num_of_features = cuConstTreeParams.num_of_features;
    int max_bin_size = cuConstTreeParams.max_bin_size;
    int num_of_classes = cuConstTreeParams.num_of_classes;    
    float* _histogram_ = cuConstTreeParams.cuda_histogram_ptr;

    // index: feature id
    int index = blockIdx.x * blockDim.x + threadIdx.x;  
    if (index >= num_of_features) return;

    float* buf_merge = new float[2 * max_bin_size + 1];

    float* histo_for_class_0 = CUDA_get_histogram_array(histogram_id, index, NEG_LABEL, _histogram_, num_of_features, num_of_classes, max_bin_size);
    float* histo_for_class_1 = CUDA_get_histogram_array(histogram_id, index, POS_LABEL, _histogram_, num_of_features, num_of_classes, max_bin_size);
    // initialize the buf_merge
    memcpy(buf_merge, histo_for_class_0, sizeof(float) * (2 * max_bin_size + 1));
    CUDA_merge_array_pointers(buf_merge, histo_for_class_1, max_bin_size);
    cuda_feature_value_num[index] = CUDA_uniform_array(cuda_feature_value + index * num_of_features, histogram_id, index, 0, buf_merge, num_of_features, num_of_classes, max_bin_size);        

    // write the result of possible splits 
    // into cuda arrays     
    for (int i = 0; i < cuda_feature_value_num[index]; i++) {
        cuda_feature_id[index * max_bin_size + i] = index;        
    }     
    delete[] buf_merge;    
}

/*
 * Calculate the entropy gain = H(Y) - H(Y|X)
 * H(Y|X) needs parameters p(X<a), p(Y=0|X<a), p(Y=0|X>=a)
 * Assuming binary classification problem
 */
__device__
void CUDA_get_gain(int histogram_id, int total_sum, int feature_id, int split_index,
    int* cuda_feature_id, float* cuda_feature_value, float* cuda_gain, float* cuda_entropy) {     

    float sum_class_0 = CUDA_get_total_array(histogram_id, feature_id, NEG_LABEL, cuConstTreeParams.cuda_histogram_ptr, cuConstTreeParams.num_of_features, cuConstTreeParams.num_of_classes, cuConstTreeParams.max_bin_size);
    float sum_class_1 = CUDA_get_total_array(histogram_id, feature_id, POS_LABEL, cuConstTreeParams.cuda_histogram_ptr, cuConstTreeParams.num_of_features, cuConstTreeParams.num_of_classes, cuConstTreeParams.max_bin_size);

    float left_sum_class_0 = CUDA_sum_array(histogram_id, feature_id, NEG_LABEL, cuda_feature_value[split_index], cuConstTreeParams.cuda_histogram_ptr, cuConstTreeParams.num_of_features, cuConstTreeParams.num_of_classes, cuConstTreeParams.max_bin_size);
    float right_sum_class_0 = sum_class_0 - left_sum_class_0;
    float left_sum_class_1 = CUDA_sum_array(histogram_id, feature_id, POS_LABEL, cuda_feature_value[split_index], cuConstTreeParams.cuda_histogram_ptr, cuConstTreeParams.num_of_features, cuConstTreeParams.num_of_classes, cuConstTreeParams.max_bin_size);
    float right_sum_class_1 = sum_class_1 - left_sum_class_1;
    float left_sum = left_sum_class_0 + left_sum_class_1;
    float right_sum = right_sum_class_0 + right_sum_class_1;

    float px = (left_sum_class_0 + left_sum_class_1) / (1.0 * total_sum); // p(x<a)
    float py_x0 = (left_sum <= EPS) ? 0.f : left_sum_class_0 / left_sum;                            // p(y=0|x < a)
    float py_x1 = (right_sum <= EPS) ? 0.f : right_sum_class_0 / right_sum;                          // p(y=0|x >= a)
    float entropy_left = ((1-py_x0) < EPS || py_x0 < EPS) ? 0 : -py_x0 * log2((double)py_x0) - (1-py_x0)*log2((double)1-py_x0);
    float entropy_right = ((1-py_x1) < EPS || py_x1 < EPS) ? 0 : -py_x1 * log2((double)py_x1) - (1-py_x1)*log2((double)1-py_x1);
    float H_YX = px * entropy_left + (1-px) * entropy_right;
    float px_prior = sum_class_0 / (sum_class_0 + sum_class_1);
    
    cuda_entropy[split_index] = ((1-px_prior) < EPS || px_prior < EPS) ? 0 : -px_prior * log2((double)px_prior) - (1-px_prior) * log2((double)1-px_prior);
    cuda_gain[split_index] = cuda_entropy[split_index] - H_YX;
}

__global__ void
calculate_gain_deltas_kernel(int histogram_id, int data_size,
    int* cuda_feature_value_num, int* cuda_feature_id, float* cuda_feature_value, float* cuda_gain, float* cuda_entropy) {
            
    // index: feature id
    int feature_id = blockIdx.x;
    int split_id = threadIdx.x;

    if (feature_id >= cuConstTreeParams.num_of_features) return;
    if (split_id >= cuda_feature_value_num[feature_id]) return;

    int split_index = feature_id * cuConstTreeParams.max_bin_size + split_id;    
    
    CUDA_get_gain(histogram_id, data_size, feature_id, split_index,
        cuda_feature_id, cuda_feature_value, cuda_gain, cuda_entropy);    
}

__global__ void
find_most_gain_kernel(int histogram_id, int data_size, int *max_gain_index, int *max_gain_feature_id, float *max_gain_value, float *max_gain, float *max_gain_entropy,
    int* cuda_feature_value_num, int* cuda_feature_id, float* cuda_feature_value, float* cuda_gain, float* cuda_entropy) {
                
    int feature_id = blockIdx.x;
    int split_id = threadIdx.x;

    if (feature_id >= cuConstTreeParams.num_of_features) return;
    if (split_id >= cuda_feature_value_num[feature_id]) return;

    int split_index = feature_id * cuConstTreeParams.max_bin_size + split_id;    
    
    if (cuda_gain[split_index] >= cuda_gain[*max_gain_index]) {
        *max_gain_index = split_index;
    }
    __syncthreads(); 

    *max_gain_feature_id = cuda_feature_id[*max_gain_index];
    *max_gain_value = cuda_feature_value[*max_gain_index];
    *max_gain = cuda_gain[*max_gain_index];
    *max_gain_entropy = cuda_entropy[*max_gain_index];
}
/*
 * This function return the best split point at a given leaf node.
 * Best split is store in `split`
*/
void DecisionTree::find_best_split(TreeNode *node, SplitPoint &split)
{              
    assert(node != NULL); 
    Timer t;      

    // store the number of possible splits
    // for each feature_id
    // feature_value_num[i]: there are feature_value_num[i] possible split values
    // valid in feture_value array for feature id i
    // from feature_value[i * num_of_features]
    // to feature_value[i * num_of_features + feature_value_num[i] - 1]
    int* cuda_feature_value_num;
    t.reset();
    gpuErrchk(cudaMalloc(&cuda_feature_value_num, sizeof(int) * num_of_features));    
    COMMUNICATION_TIME += t.elapsed();
    
    // store the split points into four arrays in device
    int* cuda_feature_id;
    float* cuda_feature_value;    
	float* cuda_gain;
    float* cuda_entropy;

    int split_point_num = num_of_features * max_bin_size;

    t.reset();
    gpuErrchk(cudaMalloc(&cuda_feature_id, sizeof(int) * split_point_num));
    gpuErrchk(cudaMalloc(&cuda_feature_value, sizeof(float) * split_point_num));
    gpuErrchk(cudaMalloc(&cuda_gain, sizeof(float) * split_point_num));
    gpuErrchk(cudaMalloc(&cuda_entropy, sizeof(float) * split_point_num));
    COMMUNICATION_TIME += t.elapsed();
    
    // first, build an array of feature_id, feature_value
    // as possible split points    
    
    int thread_num = 128;
    int block_num = (num_of_features + thread_num - 1) / thread_num;
    calculate_feature_value_kernel<<<block_num, thread_num>>>
        (node->histogram_id, cuda_feature_value_num, cuda_feature_id, cuda_feature_value); 
    cudaDeviceSynchronize();          
    // second, calcualte the gain and entropy
    // for these split points    
    // blockIdx: featureId
    // thread num: max_bin_size
    // block_num = num_of_features;
    // thread_num = max_bin_size;
    calculate_gain_deltas_kernel<<<block_num, thread_num>>>(node->histogram_id, node->data_size, cuda_feature_value_num, cuda_feature_id, cuda_feature_value, cuda_gain, cuda_entropy);
    cudaDeviceSynchronize();    
    
    // third, choose the max gain, put it into split
    // as final result
    // parse data to CPU
    int feature_value_num[num_of_features];        
    int feature_id[split_point_num];
    float feature_value[split_point_num];    
	float gain[split_point_num];    
    float entropy[split_point_num];
    
    t.reset();
    cudaMemcpy(feature_value_num,
        cuda_feature_value_num,
        sizeof(int) * num_of_features,
        cudaMemcpyDeviceToHost); 
    // for (int i = 0; i < num_of_features; i++) {
    //     if (feature_value_num[i] > 0) {
    //         printf("%d ", feature_value_num[i]);
    //     }        
    // }
    // printf("\n");

    cudaMemcpy(feature_id,
        cuda_feature_id,
        sizeof(int) * split_point_num,
        cudaMemcpyDeviceToHost); 

    // for (int i = 0; i < split_point_num; i++) {
    //     if (feature_id[i] > 0) {
    //         printf("%d ", feature_id[i]);
    //     }
    // }
    // printf("\n");

    cudaMemcpy(feature_value,
        cuda_feature_value,
        sizeof(float) * split_point_num,
        cudaMemcpyDeviceToHost); 
    // for (int i = 0; i < split_point_num; i++) {
    //     if (feature_value[i] > 0) {
    //         printf("%f ", feature_value[i]);
    //     }        
    // }
    // printf("\n");  

    cudaMemcpy(gain,
        cuda_gain,
        sizeof(int) * split_point_num,
        cudaMemcpyDeviceToHost); 

    // for (int i = 0; i < split_point_num; i++) {
    //     if (gain[i] > 0) {
    //         printf("%f ", gain[i]);
    //     }        
    // }
    // printf("\n");

    cudaMemcpy(entropy,
        cuda_entropy,
        sizeof(float) * split_point_num,
        cudaMemcpyDeviceToHost); 

    // for (int i = 0; i < split_point_num; i++) {
    //     if (entropy[i] > 0) {
    //         printf("%f ", entropy[i]);
    //     }        
    // }
    // printf("\n");

    COMMUNICATION_TIME += t.elapsed();
    split.gain = 0;
    for (int i = 0; i < num_of_features; i++) {        
        for (int j = 0; j < feature_value_num[i]; j++) {            
            if (gain[i * max_bin_size + j] > split.gain) {
                split.gain = gain[i * max_bin_size + j];
                split.feature_id = feature_id[i * max_bin_size + j];
                split.feature_value = feature_value[i * max_bin_size + j];
                split.entropy = entropy[i * max_bin_size + j];                
            }
        }
    }

    // // UNFINISHED GPU version for step 3
    // // BUGGY version, could not find the max gain
    // block_num = num_of_features;
    // thread_num = max_bin_size;
    // int max_gain_index = 0;
    // int max_gain_feature_id;
    // float max_gain_value;
    // float max_gain;
    // float max_gain_entropy;

    // find_most_gain_kernel<<<block_num, thread_num>>>(
    //     node->histogram_id, 
    //     node->data_size, 
    //     &max_gain_index, 
    //     &max_gain_feature_id, 
    //     &max_gain_value, 
    //     &max_gain, 
    //     &max_gain_entropy,
    //     cuda_feature_value_num, 
    //     cuda_feature_id, 
    //     cuda_feature_value, 
    //     cuda_gain, 
    //     cuda_entropy);
    // cudaDeviceSynchronize();    

    // split.feature_id = max_gain_feature_id;
    // split.feature_value = max_gain_value;
    // split.entropy = max_gain_entropy;
    // split.gain = max_gain;  

    // printf("split.feature_id %d\n", split.feature_id);
    // printf("split.feature_value %f\n", split.feature_value);
    // printf("split.entropy %f\n", split.entropy);
    // printf("split.gain %f\n", split.gain);

    cudaFree(cuda_feature_value_num);
    cudaFree(cuda_feature_id);
    cudaFree(cuda_feature_value);
    cudaFree(cuda_gain);
    cudaFree(cuda_entropy);
}

/*
 * This function compress the data into histograms.
 * Each unlabeled leaf would have a (num_feature, num_class) histograms
 * This function takes the assumption that each leaf is re-initialized (we use a batch mode)
*/
void DecisionTree::compress(vector<TreeNode *> &unlabeled_leaf) {
    // int block_num = this->datasetPointer->num_of_data;
    // int thread_per_block = num_of_features;                                 
    // histogram_update_kernel<<<block_num, thread_per_block>>>();      
        
    int block_num = unlabeled_leaf.size();
    int thread_per_block = num_of_features;
    Timer t;
    
    gpuErrchk(cudaMemset(cuda_histogram_ptr, 0, sizeof(float) * SIZE));   

    histogram_update_kernel_2<<<block_num, thread_per_block>>>();         

    cudaDeviceSynchronize();
    t.reset();
    cudaMemcpy(histogram,
        cuda_histogram_ptr,
        sizeof(float) * SIZE,
        cudaMemcpyDeviceToHost);  
    COMMUNICATION_TIME += t.elapsed();

    // float *histo = NULL;
    // int bin_size = 0;
    // for (int i = 0; i < num_of_features; i++) {
    //     for (int j = 0; j < num_of_classes; j++) {
    //         histo = get_histogram_array(0, i, j);
    //         bin_size = get_bin_size(histo);
    //         printf("[%d][%d]: bin_size %d\n", i, j, bin_size);
    //     }
    // }    
    
    // // sequential version for DEBUG!!!
    // // Construct the histogram. and navigate each data to its leaf.    
    // for (int data_id = 0; data_id < this->datasetPointer->num_of_data; data_id++) {
    //     for (int feature_id = 0; feature_id < num_of_features; feature_id++) {
    //         update_array(
    //             this->datasetPointer->histogram_id_ptr[data_id], 
    //             feature_id, 
    //             this->datasetPointer->label_ptr[data_id], 
    //             this->datasetPointer->value_ptr[data_id * num_of_features + feature_id]);
    //     }        
    // }   
}

/*
 * Serial version of training.
*/
void DecisionTree::train_on_batch(Dataset &train_data)
{       
    float pos_rate = ((float) train_data.num_pos_label) / train_data.num_of_data;
    dbg_assert(pos_rate > 0 && pos_rate < 1);
    root->num_pos_label = train_data.num_pos_label;
    root->entropy = - pos_rate * log2((double)pos_rate) - (1-pos_rate) * log2((double)(1-pos_rate));
    batch_initialize(root); // Reinitialize every leaf in T as unlabeled.
    vector<TreeNode *> unlabeled_leaf = __get_unlabeled(root);
    dbg_assert(unlabeled_leaf.size() <= max_num_leaves);
    while (!unlabeled_leaf.empty())
    {        
        // each while loop would add a new level node.
        this->cur_depth++;
        dbg_printf("Depth [%d] finished\n", this->cur_depth);
        vector<TreeNode *> unlabeled_leaf_new; 
        if (unlabeled_leaf.size() > max_num_leaves) {
            for (int i = 0; i < unlabeled_leaf.size(); i++) {
                unlabeled_leaf[i]->set_label();
                this->num_leaves++;
            }
            break;
        }       
        init_histogram(unlabeled_leaf);
        Timer t1 = Timer();
        t1.reset();
        compress(unlabeled_leaf); 
        COMPRESS_TIME += t1.elapsed();         
        for (auto &cur_leaf : unlabeled_leaf)
        {            
            if (is_terminated(cur_leaf))
            {         
                cur_leaf->set_label();
                this->num_leaves++;             
            }
            else
            {                
                SplitPoint best_split;                
                Timer t2 = Timer();
                t2.reset();
                find_best_split(cur_leaf, best_split);
                SPLIT_TIME += t2.elapsed();                
                dbg_ensures(best_split.gain >= -EPS);
                if (best_split.gain <= min_gain){
                    dbg_printf("Node terminated: gain=%.4f <= %.4f\n", min_node_size, best_split.gain, min_gain);
                    cur_leaf->set_label();
                    this->num_leaves++;               
                    continue;
                }
                cur_leaf->left_node = new TreeNode(this->cur_depth, this->num_nodes++, datasetPointer);
                cur_leaf->right_node = new TreeNode(this->cur_depth, this->num_nodes++, datasetPointer);
                cur_leaf->split(best_split, cur_leaf->left_node, cur_leaf->right_node);
                cur_leaf->is_leaf = false;
                cur_leaf->label = -1;
                unlabeled_leaf_new.push_back(cur_leaf->left_node);
                unlabeled_leaf_new.push_back(cur_leaf->right_node);
            }
        }
        unlabeled_leaf = unlabeled_leaf_new;
        unlabeled_leaf_new.clear(); 
    }
    self_check();    
}

void DecisionTree::self_check(){
    queue<TreeNode *> q;
    q.push(root);
    int count_leaf=0;
    int count_nodes=0;
    while (!q.empty())
    {
        auto tmp_ptr = q.front();
        q.pop();
        count_nodes++;
        if (tmp_ptr == NULL)
        {
            // should never reach here.
            fprintf(stderr, "ERROR: The tree contains node that have only one child\n");
            exit(-1);
        }
        else if ((tmp_ptr->left_node == NULL) && (tmp_ptr->right_node == NULL))
        {
            dbg_requires(tmp_ptr->is_leaf);
            dbg_requires(tmp_ptr->label == POS_LABEL || tmp_ptr->label == NEG_LABEL);
            count_leaf++;
        }
        else
        {
            dbg_requires(!tmp_ptr->is_leaf);
            dbg_requires(tmp_ptr->label == -1);
            q.push(tmp_ptr->left_node);
            q.push(tmp_ptr->right_node);
        }
    }
    dbg_assert(count_leaf == num_leaves);
    dbg_assert(count_nodes == num_nodes);
    dbg_printf("------------------------------------------------\n");
    dbg_printf("| Num_leaf: %d, num_nodes: %d, max_depth: %d | \n", num_leaves, num_nodes, cur_depth);
    dbg_printf("------------------------------------------------\n");

}


/* 
 * This function reture all the unlabeled leaf nodes in a breadth-first manner.
*/
vector<TreeNode *> DecisionTree::__get_unlabeled(TreeNode *node)
{
    queue<TreeNode *> q;
    q.push(node);
    vector<TreeNode *> ret;
    while (!q.empty())
    {
        auto tmp_ptr = q.front();
        q.pop();
        if (tmp_ptr == NULL)
        {
            // should never reach here.
            fprintf(stderr, "ERROR: The tree contains node that have only one child\n");
            exit(-1);
        }
        else if ((tmp_ptr->left_node == NULL) && (tmp_ptr->right_node == NULL) && tmp_ptr->label < 0)
        {
            ret.push_back(tmp_ptr);
        }
        else
        {
            q.push(tmp_ptr->left_node);
            q.push(tmp_ptr->right_node);
        }
    }
    return ret;
}

/*
 * initialize each leaf as unlabeled.
 */
void DecisionTree::batch_initialize(TreeNode *node)
{
    if (node == NULL)
    {
        // should never reach here.
        fprintf(stderr, "ERROR: The tree contains node that have only one child\n");
        exit(-1);
    }
    else if ((node->left_node == NULL) && (node->right_node == NULL))
    {
       node->init();
    }
    else
    {
        batch_initialize(node->left_node);
        batch_initialize(node->right_node);
    }
    return;
}


/*
 *
 */
TreeNode *DecisionTree::navigate(int data_index, Dataset *datasetPointer)
{
    TreeNode *ptr = this->root;
    while (!ptr->is_leaf)
    {
        dbg_assert(ptr->right_node != NULL && ptr->left_node != NULL);
        ptr = (ptr->split_ptr.decision_rule(data_index, datasetPointer)) ? ptr->right_node : ptr->left_node;
    }
    return ptr;
}

__global__ void
navigate_sample_kernel(int unlabeled_leaf_size, int *cuda_histogram_id_2_node_id) {
    
    int index = blockIdx.x * blockDim.x + threadIdx.x;    
    int data_size = cuConstTreeParams.num_of_data;
    
    if (index >= data_size) return;
    int* cuda_histogram_id_ptr = cuConstTreeParams.cuda_histogram_id_ptr;
	
    for (int i = 0; i < unlabeled_leaf_size; i++) {
        if (cuda_histogram_id_ptr[index] == cuda_histogram_id_2_node_id[i]) {
            cuda_histogram_id_ptr[index] = i;
            break;
        }
    }    
    __syncthreads(); 
}

/*
 * This function initialize the histogram for each unlabeled leaf node.
 * Also, potentially, it would free the previous histogram.
 */
void DecisionTree::init_histogram(vector<TreeNode *> &unlabeled_leaf)
{
    int c = 0;      
    assert(unlabeled_leaf.size() <= max_num_leaves);   
    
    // map the histogram id to node id
    // TODO: use another map? map node id to histogram id
    int histogram_id_2_node_id[unlabeled_leaf.size()];
    int* cuda_histogram_id_2_node_id;
    
    for (auto &p : unlabeled_leaf) {
        p->histogram_id = c++;   
        // build an array index, between node's node_id and histogram_id
        histogram_id_2_node_id[p->histogram_id] = p->id;     
    }   
    Timer t;
    int thread_num = 128;
    int block_num = (this->datasetPointer->num_of_data + thread_num - 1) / thread_num;        

    // previously, store the node id in histogram_id_ptr
    t.reset();
    gpuErrchk(cudaMemcpy(cuda_histogram_id_ptr,
        this->datasetPointer->histogram_id_ptr,
        sizeof(int) * this->datasetPointer->num_of_data,
        cudaMemcpyHostToDevice)); 

    gpuErrchk(cudaMalloc(&cuda_histogram_id_2_node_id, sizeof(int) * unlabeled_leaf.size()));
    
    gpuErrchk(cudaMemcpy(cuda_histogram_id_2_node_id,
        histogram_id_2_node_id,
        sizeof(int) * unlabeled_leaf.size(),
        cudaMemcpyHostToDevice)); 
    COMMUNICATION_TIME += t.elapsed();
    // change the node id into histogram id
    navigate_sample_kernel<<<block_num, thread_num>>>(unlabeled_leaf.size(), cuda_histogram_id_2_node_id); 
    t.reset();
    cudaDeviceSynchronize();  
    cudaFree(cuda_histogram_id_2_node_id);      
}
